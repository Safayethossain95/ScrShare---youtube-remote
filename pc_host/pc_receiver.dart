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
    case 'esc':
      sendKey = '{ESC}';
      break;
    case 'captions':
    case 'subtitles':
    case 'cc':
      sendKey = 'c';
      break;
  }

  if (sendKey != null) {
    final cmd = "\$wshell = New-Object -ComObject wscript.shell; \$activated = \$wshell.AppActivate('YouTube'); if (!\$activated) { \$activated = \$wshell.AppActivate('Chrome'); } if (!\$activated) { \$wshell.AppActivate('Edge'); } \$wshell.SendKeys('$sendKey')";
    Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', cmd]);
  }
}

void executeSearch(String query) async {
  final q = query.trim();
  print('[SEARCH] Opening YouTube TV search: $q');
  if (!Platform.isWindows) return;

  final escaped = q.replaceAllMapped(RegExp(r'[+^%~(){}[\]]'), (m) => '{${m[0]}}');

  final script = '''
\$wshell = New-Object -ComObject wscript.shell;
\$activated = \$wshell.AppActivate('YouTube');
if (!\$activated) { \$activated = \$wshell.AppActivate('Edge'); }
if (!\$activated) { \$activated = \$wshell.AppActivate('Chrome'); }
Start-Sleep -Milliseconds 60;
\$wshell.SendKeys('{BACKSPACE}');
Start-Sleep -Milliseconds 150;
\$wshell.SendKeys('{LEFT}');
Start-Sleep -Milliseconds 80;
1..6 | ForEach-Object { \$wshell.SendKeys('{UP}'); Start-Sleep -Milliseconds 30; }
Start-Sleep -Milliseconds 80;
\$wshell.SendKeys('{ENTER}');
${q.isNotEmpty ? '''
Start-Sleep -Milliseconds 450;
\$wshell.SendKeys('$escaped');
Start-Sleep -Milliseconds 150;
\$wshell.SendKeys('{ENTER}');
''' : ''}
''';

  await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
}

void startUdpResponder(String localIp) async {
  try {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
    socket.broadcastEnabled = true;

    socket.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket.receive();
        if (datagram != null) {
          try {
            final msg = utf8.decode(datagram.data, allowMalformed: true).trim();
            if (msg == 'SCRSHARE_DISCOVER') {
              final reply = jsonEncode({
                'type': 'SCRSHARE_HOST',
                'name': Platform.localHostname,
                'ip': localIp,
                'port': httpPort,
                'os': Platform.operatingSystem,
              });
              socket.send(utf8.encode(reply), datagram.address, datagram.port);
            } else if (msg.startsWith('Q:')) {
              executeSearch(msg.substring(2));
            } else if (msg.startsWith('K:')) {
              executeKeyAction(msg.substring(2));
            }
          } catch (_) {}
        }
      }
    });
  } catch (e) {
    print('[UDP Warning] Discovery port error: $e');
  }
}

void main() async {
  try {
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
    } else if (path == '/search') {
      String query = '';
      if (request.method == 'POST') {
        final content = await utf8.decoder.bind(request).join();
        if (content.isNotEmpty) {
          try {
            final body = jsonDecode(content);
            if (body is Map) {
              query = (body['q'] ?? body['query'] ?? '').toString();
            }
          } catch (_) {}
        }
      } else if (request.uri.queryParameters.containsKey('q')) {
        query = request.uri.queryParameters['q']!;
      } else if (request.uri.queryParameters.containsKey('query')) {
        query = request.uri.queryParameters['query']!;
      }

      executeSearch(query);

      request.response
        ..headers.contentType = ContentType.json
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode({'success': true, 'query': query}));
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not found');
    }

    await request.response.close();
  }
} catch (e) {
  print('\n[ERROR] Unable to start PC Receiver server: $e');
  if (e.toString().contains('10048') || e.toString().contains('already in use')) {
    print('\n>>> Port $httpPort is already being used!');
    print('>>> An existing instance of pc_receiver.exe is likely already running in the background.');
    print('>>> Please check Task Manager and end any running "pc_receiver.exe" processes.\n');
  }
  print('Press [Enter] to exit...');
  try {
    stdin.readLineSync();
  } catch (_) {}
  exit(1);
}
}
