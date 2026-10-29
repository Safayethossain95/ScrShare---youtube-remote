// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

const int httpPort = 8080;
const int udpPort = 8088;

Future<String> getLocalIp() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback &&
            (addr.address.startsWith('192.168.') ||
                addr.address.startsWith('10.') ||
                addr.address.startsWith('172.'))) {
          return addr.address;
        }
      }
    }
    if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
      return interfaces.first.addresses.first.address;
    }
  } catch (_) {}
  return '127.0.0.1';
}

void launchBrowser(String url) {
  print('[LAUNCH] Opening browser: $url');
  if (Platform.isWindows) {
    Process.run('cmd.exe', ['/c', 'start', '', url]);
  } else if (Platform.isMacOS) {
    Process.run('open', [url]);
  } else {
    Process.run('xdg-open', [url]);
  }
}

void executeKeyAction(String action) {
  final key = action.toLowerCase().trim();
  print('[ACTION] Executing: $key');

  if (!Platform.isWindows) return;

  String? sendKey;
  switch (key) {
    case 'fullscreen':
      sendKey = '{F11}';
      break;
    case 'play_pause':
    case 'space':
      sendKey = ' ';
      break;
    case 'mute':
      sendKey = 'm';
      break;
    case 'navigate_up':
    case 'up':
    case 'volume_up':
      sendKey = '{UP}';
      break;
    case 'navigate_down':
    case 'down':
    case 'volume_down':
      sendKey = '{DOWN}';
      break;
    case 'navigate_left':
    case 'left':
      sendKey = '{LEFT}';
      break;
    case 'navigate_right':
    case 'right':
      sendKey = '{RIGHT}';
      break;
    case 'select':
    case 'enter':
    case 'ok':
      sendKey = '{ENTER}';
      break;
    case 'back':
    case 'backspace':
      sendKey = '{BACKSPACE}';
      break;
    case 'escape':
      sendKey = '{ESC}';
      break;
  }

  if (sendKey != null) {
    final cmd = '\$wshell = New-Object -ComObject wscript.shell; \$wshell.SendKeys("$sendKey")';
    Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', cmd]);
  }
}

void startUdpResponder(String localIp) async {
  try {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
    socket.broadcastEnabled = true;

    socket.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket.receive();
        if (datagram != null) {
          final msg = utf8.decode(datagram.data).trim();
          if (msg == 'SCRSHARE_DISCOVER') {
            final reply = jsonEncode({
              'type': 'SCRSHARE_HOST',
              'name': Platform.localHostname,
              'ip': localIp,
              'port': httpPort,
              'os': Platform.operatingSystem,
            });
            socket.send(utf8.encode(reply), datagram.address, datagram.port);
          }
        }
      }
    });
  } catch (e) {
    print('[UDP Warning] Discovery port error: $e');
  }
}

void main() async {
  final localIp = await getLocalIp();

  print('=' * 60);
  print('  SCRSHARE - PC NATIVE RECEIVER (STANDALONE .EXE)');
  print('=' * 60);
  print('  PC Local Wi-Fi IP : http://$localIp:$httpPort');
  print('  Hostname          : ${Platform.localHostname}');
  print('  Discovery Port    : $udpPort (UDP)');
  print('=' * 60);
  print('  Status: READY and waiting for phone commands...');
  print('  Press Ctrl+C to exit.');
  print('=' * 60);

  startUdpResponder(localIp);

  final server = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);

  await for (final request in server) {
    // Enable CORS
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      continue;
    }

    final path = request.uri.path;

    if (path == '/' || path == '/status') {
      final data = {
        'status': 'online',
        'name': Platform.localHostname,
        'ip': localIp,
        'port': httpPort,
        'os': Platform.operatingSystem,
      };
      request.response
        ..headers.contentType = ContentType.json
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode(data));
    } else if (path == '/launch') {
      String targetUrl = 'https://www.youtube.com/tv';
      if (request.method == 'POST') {
        final content = await utf8.decoder.bind(request).join();
        if (content.isNotEmpty) {
          try {
            final body = jsonDecode(content);
            if (body is Map && body.containsKey('url')) {
              targetUrl = body['url'].toString();
            }
          } catch (_) {}
        }
      } else if (request.uri.queryParameters.containsKey('url')) {
        targetUrl = request.uri.queryParameters['url']!;
      }

      launchBrowser(targetUrl);

      request.response
        ..headers.contentType = ContentType.json
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode({'success': true, 'url': targetUrl}));
    } else if (path == '/action') {
      String action = '';
      if (request.method == 'POST') {
        final content = await utf8.decoder.bind(request).join();
        if (content.isNotEmpty) {
          try {
            final body = jsonDecode(content);
            if (body is Map && body.containsKey('command')) {
              action = body['command'].toString();
            }
          } catch (_) {}
        }
      } else if (request.uri.queryParameters.containsKey('command')) {
        action = request.uri.queryParameters['command']!;
      }

      executeKeyAction(action);

      request.response
        ..headers.contentType = ContentType.json
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode({'success': true, 'action': action}));
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not found');
    }

    await request.response.close();
  }
}
