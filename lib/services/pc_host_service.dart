import 'dart:async';
import 'dart:convert';
import 'dart:io';

class LogEvent {
  final DateTime timestamp;
  final String title;
  final String detail;
  final bool isSuccess;

  LogEvent({
    required this.title,
    required this.detail,
    this.isSuccess = true,
  }) : timestamp = DateTime.now();
}

class PCHostService {
  static final PCHostService _instance = PCHostService._internal();
  factory PCHostService() => _instance;
  PCHostService._internal();

  HttpServer? _httpServer;
  RawDatagramSocket? _udpSocket;
  bool _isRunning = false;
  int _port = 8080;
  static const int udpDiscoveryPort = 8088;

  final StreamController<LogEvent> _logController = StreamController<LogEvent>.broadcast();
  Stream<LogEvent> get onLog => _logController.stream;

  final List<LogEvent> _logs = [];
  List<LogEvent> get logs => List.unmodifiable(_logs);

  bool get isRunning => _isRunning;
  int get port => _port;
  String? _detectedIp;
  String? get detectedIp => _detectedIp;

  void _addLog(String title, String detail, {bool isSuccess = true}) {
    final event = LogEvent(title: title, detail: detail, isSuccess: isSuccess);
    _logs.insert(0, event);
    if (_logs.length > 100) _logs.removeLast();
    _logController.add(event);
  }

  Future<String> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && (addr.address.startsWith('192.168.') || addr.address.startsWith('10.') || addr.address.startsWith('172.'))) {
            _detectedIp = addr.address;
            return addr.address;
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        _detectedIp = interfaces.first.addresses.first.address;
        return _detectedIp!;
      }
    } catch (e) {
      // fallback
    }
    _detectedIp = '127.0.0.1';
    return '127.0.0.1';
  }

  Future<bool> startServer({int port = 8080}) async {
    if (_isRunning) return true;
    _port = port;

    try {
      await getLocalIp();

      // 1. Start HTTP Server
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _httpServer!.listen(_handleHttpRequest);

      // 2. Start UDP Discovery responder
      try {
        _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpDiscoveryPort);
        _udpSocket!.broadcastEnabled = true;
        _udpSocket!.listen(_handleUdpMessage);
      } catch (udpError) {
        _addLog('UDP Warning', 'Discovery port $udpDiscoveryPort busy or restricted: $udpError', isSuccess: false);
      }

      _isRunning = true;
      _addLog('Host Server Started', 'Listening at http://$_detectedIp:$_port');
      return true;
    } catch (e) {
      _isRunning = false;
      _addLog('Start Error', 'Could not bind to port $_port: $e', isSuccess: false);
      return false;
    }
  }

  Future<void> stopServer() async {
    await _httpServer?.close(force: true);
    _udpSocket?.close();
    _httpServer = null;
    _udpSocket = null;
    _isRunning = false;
    _addLog('Host Stopped', 'Server has been shut down');
  }

  void _handleHttpRequest(HttpRequest request) async {
    // Add CORS headers for web/browser clients
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    final clientIp = request.connectionInfo?.remoteAddress.address ?? 'Remote';

    try {
      if (path == '/' || path == '/status') {
        final statusData = {
          'status': 'online',
          'name': Platform.localHostname,
          'os': Platform.operatingSystem,
          'port': _port,
          'ip': _detectedIp ?? '127.0.0.1',
          'app': 'ScrShare Host',
          'version': '1.0.0',
        };
        request.response
          ..headers.contentType = ContentType.json
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode(statusData));
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

        final result = await launchUrlOnHost(targetUrl);
        _addLog(
          'Launch Request',
          'From $clientIp -> Opened "$targetUrl"',
          isSuccess: result,
        );

        request.response
          ..headers.contentType = ContentType.json
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode({
            'success': result,
            'message': result ? 'Launched successfully' : 'Failed to launch URL',
            'url': targetUrl,
          }));
      } else if (path == '/action') {
        String action = '';
        if (request.method == 'POST') {
          final content = await utf8.decoder.bind(request).join();
          if (content.isNotEmpty) {
            final body = jsonDecode(content);
            if (body is Map && body.containsKey('command')) {
              action = body['command'].toString();
            }
          }
        } else if (request.uri.queryParameters.containsKey('command')) {
          action = request.uri.queryParameters['command']!;
        }

        final result = await executeHostAction(action);
        _addLog(
          'Remote Action',
          'From $clientIp -> Executed "$action"',
          isSuccess: result,
        );

        request.response
          ..headers.contentType = ContentType.json
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode({
            'success': result,
            'action': action,
          }));
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not found');
      }
    } catch (e) {
      _addLog('Request Error', 'Error processing $path: $e', isSuccess: false);
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Server error: $e');
    } finally {
      await request.response.close();
    }
  }

  void _handleUdpMessage(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final datagram = _udpSocket?.receive();
      if (datagram != null) {
        final message = utf8.decode(datagram.data).trim();
        if (message == 'SCRSHARE_DISCOVER') {
          final replyPayload = jsonEncode({
            'type': 'SCRSHARE_HOST',
            'name': Platform.localHostname,
            'ip': _detectedIp ?? '127.0.0.1',
            'port': _port,
            'os': Platform.operatingSystem,
          });
          final replyBytes = utf8.encode(replyPayload);
          _udpSocket?.send(replyBytes, datagram.address, datagram.port);
        }
      }
    }
  }

  /// Launches the URL on the host operating system's default browser
  Future<bool> launchUrlOnHost(String url) async {
    try {
      if (Platform.isWindows) {
        // Use cmd.exe start with empty title parameter to open default browser
        final result = await Process.run('cmd.exe', ['/c', 'start', '', url]);
        return result.exitCode == 0;
      } else if (Platform.isMacOS) {
        final result = await Process.run('open', [url]);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        final result = await Process.run('xdg-open', [url]);
        return result.exitCode == 0;
      } else {
        return false;
      }
    } catch (e) {
      return false;
    }
  }

  /// Sends keyboard actions (F11 fullscreen, Space play/pause, Arrows, etc.)
  Future<bool> executeHostAction(String action) async {
    if (!Platform.isWindows) return true;

    String? keyToSend;
    switch (action.toLowerCase()) {
      case 'fullscreen':
        keyToSend = '{F11}';
        break;
      case 'play_pause':
        keyToSend = ' ';
        break;
      case 'mute':
        keyToSend = 'm';
        break;
      case 'navigate_up':
      case 'up':
        keyToSend = '{UP}';
        break;
      case 'navigate_down':
      case 'down':
        keyToSend = '{DOWN}';
        break;
      case 'navigate_left':
      case 'left':
        keyToSend = '{LEFT}';
        break;
      case 'navigate_right':
      case 'right':
        keyToSend = '{RIGHT}';
        break;
      case 'select':
      case 'enter':
        keyToSend = '{ENTER}';
        break;
      case 'back':
      case 'backspace':
        keyToSend = '{BACKSPACE}';
        break;
      case 'escape':
        keyToSend = '{ESC}';
        break;
    }

    if (keyToSend == null) return false;

    try {
      // PowerShell send keys via WScript.Shell
      final command = '\$wshell = New-Object -ComObject wscript.shell; \$wshell.SendKeys("$keyToSend")';
      final result = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', command]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
