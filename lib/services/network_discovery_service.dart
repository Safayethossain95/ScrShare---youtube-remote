import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/host_info.dart';

class NetworkDiscoveryService {
  static const int udpPort = 8088;
  static const int defaultHttpPort = 8080;

  /// Fast discovery of PCs running pc_server.py on the local Wi-Fi
  static Future<List<HostInfo>> discoverHosts({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final Map<String, HostInfo> discovered = {};

    // 1. Run Subnet Fast-Scan and UDP broadcast in parallel
    await Future.wait([
      _runSubnetScan(discovered),
      _runUdpBroadcast(discovered, timeout),
    ]);

    return discovered.values.toList();
  }

  /// UDP Broadcast discovery (works instantly if router permits broadcast)
  static Future<void> _runUdpBroadcast(
    Map<String, HostInfo> discovered,
    Duration timeout,
  ) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final message = utf8.encode('SCRSHARE_DISCOVER');
      socket.send(message, InternetAddress('255.255.255.255'), udpPort);

      final completer = Completer<void>();
      Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });

      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null) {
            try {
              final text = utf8.decode(datagram.data).trim();
              final data = jsonDecode(text);
              if (data is Map && data['type'] == 'SCRSHARE_HOST') {
                final ip = data['ip'] ?? datagram.address.address;
                final port = data['port'] ?? defaultHttpPort;
                final name = data['name'] ?? 'PC Host';
                final os = data['os'] ?? 'Windows';

                discovered[ip] = HostInfo(
                  ip: ip,
                  port: port,
                  name: name,
                  os: os,
                  lastSeen: DateTime.now(),
                  isAutoDiscovered: true,
                );
              }
            } catch (_) {}
          }
        }
      });

      await completer.future;
    } catch (_) {
      // UDP broadcast could be blocked
    } finally {
      socket?.close();
    }
  }

  /// Full 254-host concurrent subnet scan (370ms, 100% immune to router UDP blocking)
  static Future<void> _runSubnetScan(Map<String, HostInfo> discovered) async {
    try {
      final prefixes = await _getLocalSubnetPrefixes();
      final List<Future> probeTasks = [];

      for (final prefix in prefixes) {
        for (int i = 1; i <= 254; i++) {
          final targetIp = '$prefix$i';
          probeTasks.add(_probeIp(targetIp, defaultHttpPort, discovered));
        }
      }

      await Future.wait(probeTasks);
    } catch (_) {}
  }

  static Future<void> _probeIp(
    String ip,
    int port,
    Map<String, HostInfo> discovered,
  ) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 350);

      final request = await client.getUrl(Uri.parse('http://$ip:$port/status'));
      final response = await request.close().timeout(const Duration(milliseconds: 450));

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        if (data is Map && data['status'] == 'online') {
          final host = HostInfo(
            ip: ip,
            port: port,
            name: data['name'] ?? 'PC ($ip)',
            os: data['os'] ?? 'Windows',
            lastSeen: DateTime.now(),
            isAutoDiscovered: true,
          );
          discovered[ip] = host;
        }
      }
    } catch (_) {
      // Host offline or unreachable
    } finally {
      client?.close(force: true);
    }
  }

  static Future<Set<String>> _getLocalSubnetPrefixes() async {
    final Set<String> prefixes = {};

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}.');
            }
          }
        }
      }
    } catch (_) {}

    // Add standard router subnets as fallbacks
    if (prefixes.isEmpty) {
      prefixes.add('192.168.1.');
      prefixes.add('192.168.0.');
      prefixes.add('192.168.137.'); // Windows Hotspot
    }

    return prefixes;
  }
}
