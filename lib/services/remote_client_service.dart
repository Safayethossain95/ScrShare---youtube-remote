import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/host_info.dart';

class RemoteClientService {
  static final RemoteClientService _instance = RemoteClientService._internal();
  factory RemoteClientService() => _instance;
  RemoteClientService._internal();

  RawDatagramSocket? _udpSocket;

  // Zero-allocation reusable buffers for binary UDP protocol
  final Uint8List _binMoveBuf = Uint8List(5);
  late final ByteData _binMoveData = ByteData.sublistView(_binMoveBuf);

  final Uint8List _binClickBuf = Uint8List(2);
  final Uint8List _binDownBuf = Uint8List(2);
  final Uint8List _binUpBuf = Uint8List(2);

  final Uint8List _binScrollBuf = Uint8List(3);
  late final ByteData _binScrollData = ByteData.sublistView(_binScrollBuf);

  final Uint8List _binMoveAbsBuf = Uint8List(5);
  late final ByteData _binMoveAbsData = ByteData.sublistView(_binMoveAbsBuf);

  Future<void> _ensureUdpSocket() async {
    if (kIsWeb) return;
    if (_udpSocket != null) return;
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {}
  }

  /// Synchronous, zero-allocation binary UDP pointer move (0ms latency, zero GC)
  void sendRawPointerMove(double dx, double dy) {
    if (_currentHost == null) return;
    if (!kIsWeb) {
      if (_udpSocket == null) _ensureUdpSocket();
      if (_udpSocket != null) {
        _binMoveBuf[0] = 0x01; // Opcode: MOVE_REL
        final int16Dx = (dx * 10).clamp(-32768, 32767).toInt();
        final int16Dy = (dy * 10).clamp(-32768, 32767).toInt();
        _binMoveData.setInt16(1, int16Dx, Endian.little);
        _binMoveData.setInt16(3, int16Dy, Endian.little);
        _udpSocket!.send(_binMoveBuf, InternetAddress(_currentHost!.ip), 8088);
      }
      return;
    }
    sendMouseMove(dx: dx, dy: dy);
  }

  void _sendUdp(String cmd) {
    if (kIsWeb || _currentHost == null) return;
    try {
      if (_udpSocket == null) {
        _ensureUdpSocket();
      }
      if (_udpSocket != null) {
        final bytes = utf8.encode(cmd);
        _udpSocket!.send(bytes, InternetAddress(_currentHost!.ip), 8088);
      }
    } catch (_) {}
  }

  HostInfo? _currentHost;
  HostInfo? get currentHost => _currentHost;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  final StreamController<bool> _connectionStateController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionChanged => _connectionStateController.stream;

  static const String keyLastHostIp = 'last_host_ip';
  static const String keyLastHostPort = 'last_host_port';
  static const String keyLastHostName = 'last_host_name';

  HostInfo? _lastSavedHost;
  HostInfo? get lastSavedHost => _lastSavedHost;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(keyLastHostIp);
    final port = prefs.getInt(keyLastHostPort) ?? 8080;
    final name = prefs.getString(keyLastHostName) ?? 'Saved PC';

    if (ip != null && ip.isNotEmpty) {
      _lastSavedHost = HostInfo(
        ip: ip,
        port: port,
        name: name,
        lastSeen: DateTime.now(),
      );
    }
    if (kIsWeb) {
      await autoConnectLocalHost();
    } else {
      _currentHost = null;
      _setConnected(false);
    }
  }

  /// Automatically connects to localhost (127.0.0.1:8080) if available
  Future<bool> autoConnectLocalHost() async {
    try {
      final uri = Uri.parse('http://127.0.0.1:8080/status');
      final res = await http.get(uri).timeout(const Duration(milliseconds: 700));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final ip = data['ip'] ?? '127.0.0.1';
        final port = data['port'] ?? 8080;
        final name = data['name'] ?? 'Local PC';
        final host = HostInfo(
          ip: kIsWeb ? '127.0.0.1' : ip.toString(),
          port: port is int ? port : int.tryParse(port.toString()) ?? 8080,
          name: name.toString(),
          lastSeen: DateTime.now(),
        );
        selectHost(host);
        return true;
      }
    } catch (_) {}
    return false;
  }

  void disconnect() {
    _currentHost = null;
    _setConnected(false);
  }

  void selectHost(HostInfo host) {
    _currentHost = host;
    _saveHost(host);
    checkConnection();
  }

  Future<void> _saveHost(HostInfo host) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyLastHostIp, host.ip);
    await prefs.setInt(keyLastHostPort, host.port);
    await prefs.setString(keyLastHostName, host.name);
  }

  Future<bool> checkConnection() async {
    if (_currentHost == null) {
      _setConnected(false);
      return false;
    }

    try {
      final response = await http
          .get(Uri.parse('${_currentHost!.baseUrl}/status'))
          .timeout(const Duration(seconds: 2));

      final success = response.statusCode == 200;
      _setConnected(success);
      return success;
    } catch (_) {
      _setConnected(false);
      return false;
    }
  }

  void _setConnected(bool status) {
    if (_isConnected != status) {
      _isConnected = status;
      _connectionStateController.add(status);
    }
  }

  /// Launch YouTube TV or any custom URL on the PC's default browser
  Future<bool> launchUrl({String url = 'https://www.youtube.com/tv'}) async {
    if (_currentHost == null) return false;

    try {
      final response = await http
          .post(
            Uri.parse('${_currentHost!.baseUrl}/launch'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'url': url}),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        _setConnected(true);
        final data = jsonDecode(response.body);
        return data['success'] == true;
      }
      return false;
    } catch (_) {
      _setConnected(false);
      return false;
    }
  }

  /// Open YouTube TV search page on PC
  Future<bool> openYouTubeSearch() async {
    return searchYouTube('');
  }

  /// Search YouTube TV or open the search page with direct query sync
  Future<bool> searchYouTube(String query) async {
    if (_currentHost == null) {
      await autoConnectLocalHost();
      if (_currentHost == null) return false;
    }

    final trimmed = query.trim();

    // Fast-path UDP dispatch (<1ms latency)
    if (!kIsWeb) {
      if (trimmed.isEmpty) {
        _sendUdp('K:search');
      } else {
        _sendUdp('Q:$trimmed');
      }
      return true;
    }

    try {
      final response = await http
          .post(
            Uri.parse('${_currentHost!.baseUrl}/search'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'q': trimmed}),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        _setConnected(true);
        return true;
      }
    } catch (_) {}

    return false;
  }

  /// Get current media playback status (active, playing, position, duration, title)
  Future<Map<String, dynamic>?> getMediaStatus() async {
    if (_currentHost == null) return null;
    try {
      final response = await _httpClient
          .get(Uri.parse('${_currentHost!.baseUrl}/media/status'))
          .timeout(const Duration(milliseconds: 1500));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Seek the active YouTube video by ratio (0.0 to 1.0) and position in seconds
  Future<bool> seekMedia({required double ratio, double position = -1}) async {
    if (_currentHost == null) return false;

    final clampedRatio = ratio.clamp(0.0, 1.0);

    // Fast-path: Send immediately over UDP
    if (!kIsWeb) {
      _sendUdp('SEEK:$clampedRatio');
      return true;
    }

    try {
      final response = await _httpClient
          .post(
            Uri.parse('${_currentHost!.baseUrl}/media/seek'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'ratio': clampedRatio,
              'position': position,
            }),
          )
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send navigation or playback action to the PC
  Future<bool> sendAction(String command) async {
    if (_currentHost == null) return false;

    // Fast-path: Send over UDP immediately (<1ms latency)
    if (!kIsWeb) {
      _sendUdp('K:$command');
      return true;
    }

    try {
      final response = await http
          .post(
            Uri.parse('${_currentHost!.baseUrl}/action'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'command': command}),
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        _setConnected(true);
        return true;
      }
      return false;
    } catch (_) {
      _setConnected(false);
      return false;
    }
  }

  final http.Client _httpClient = http.Client();

  /// Send relative mouse movement (for trackpad mode)
  Future<bool> sendMouseMove({required double dx, required double dy}) async {
    if (_currentHost == null) return false;
    if (!kIsWeb) {
      _sendUdp('M:$dx,$dy');
      return true;
    }
    try {
      final response = await _httpClient.post(
        Uri.parse('${_currentHost!.baseUrl}/mouse'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'move',
          'dx': dx,
          'dy': dy,
        }),
      ).timeout(const Duration(milliseconds: 1500));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send absolute mouse movement (for screen mirroring touch)
  Future<bool> sendMouseAbsMove({required double xRatio, required double yRatio}) async {
    if (_currentHost == null) return false;
    if (!kIsWeb) {
      if (_udpSocket == null) _ensureUdpSocket();
      if (_udpSocket != null) {
        _binMoveAbsBuf[0] = 0x06;
        final u16X = (xRatio.clamp(0.0, 1.0) * 65535).toInt();
        final u16Y = (yRatio.clamp(0.0, 1.0) * 65535).toInt();
        _binMoveAbsData.setUint16(1, u16X, Endian.little);
        _binMoveAbsData.setUint16(3, u16Y, Endian.little);
        _udpSocket!.send(_binMoveAbsBuf, InternetAddress(_currentHost!.ip), 8088);
        return true;
      }
    }
    try {
      final response = await _httpClient.post(
        Uri.parse('${_currentHost!.baseUrl}/mouse'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'move_abs',
          'x': xRatio,
          'y': yRatio,
        }),
      ).timeout(const Duration(milliseconds: 1500));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send mouse click: 'left', 'right', 'middle', 'double'
  Future<bool> sendMouseClick(String button) async {
    if (_currentHost == null) return false;
    if (!kIsWeb) {
      if (_udpSocket == null) _ensureUdpSocket();
      if (_udpSocket != null) {
        _binClickBuf[0] = 0x02;
        final b = button.toLowerCase().trim();
        _binClickBuf[1] = b == 'right' ? 2 : (b == 'double' ? 3 : (b == 'middle' ? 4 : 1));
        _udpSocket!.send(_binClickBuf, InternetAddress(_currentHost!.ip), 8088);
        return true;
      }
    }
    try {
      final response = await _httpClient.post(
        Uri.parse('${_currentHost!.baseUrl}/mouse'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'click',
          'button': button,
        }),
      ).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send mouse button down (press and hold for drag)
  Future<bool> sendMouseDown(String button) async {
    if (_currentHost == null) return false;
    if (!kIsWeb) {
      if (_udpSocket == null) _ensureUdpSocket();
      if (_udpSocket != null) {
        _binDownBuf[0] = 0x03;
        _binDownBuf[1] = button.toLowerCase().trim() == 'right' ? 2 : 1;
        _udpSocket!.send(_binDownBuf, InternetAddress(_currentHost!.ip), 8088);
        return true;
      }
    }
    try {
      final response = await _httpClient.post(
        Uri.parse('${_currentHost!.baseUrl}/mouse'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'down',
          'button': button,
        }),
      ).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send mouse button up (release drag)
  Future<bool> sendMouseUp(String button) async {
    if (_currentHost == null) return false;
    if (!kIsWeb) {
      if (_udpSocket == null) _ensureUdpSocket();
      if (_udpSocket != null) {
        _binUpBuf[0] = 0x04;
        _binUpBuf[1] = button.toLowerCase().trim() == 'right' ? 2 : 1;
        _udpSocket!.send(_binUpBuf, InternetAddress(_currentHost!.ip), 8088);
        return true;
      }
    }
    try {
      final response = await _httpClient.post(
        Uri.parse('${_currentHost!.baseUrl}/mouse'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'up',
          'button': button,
        }),
      ).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send mouse wheel scroll
  Future<bool> sendMouseScroll(int delta) async {
    if (_currentHost == null) return false;
    if (!kIsWeb) {
      if (_udpSocket == null) _ensureUdpSocket();
      if (_udpSocket != null) {
        _binScrollBuf[0] = 0x05;
        _binScrollData.setInt16(1, delta.clamp(-32768, 32767).toInt(), Endian.little);
        _udpSocket!.send(_binScrollBuf, InternetAddress(_currentHost!.ip), 8088);
        return true;
      }
    }
    try {
      final response = await _httpClient.post(
        Uri.parse('${_currentHost!.baseUrl}/mouse'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'scroll',
          'delta': delta,
        }),
      ).timeout(const Duration(milliseconds: 1500));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send typed text directly to PC (supports full Unicode)
  Future<bool> sendKeyboardText(String text) async {
    if (_currentHost == null || text.isEmpty) return false;
    try {
      final response = await _httpClient.post(
        Uri.parse('${_currentHost!.baseUrl}/keyboard'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text}),
      ).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send special keyboard key to PC (e.g. 'enter', 'backspace', 'escape', 'ctrl+c', etc.)
  Future<bool> sendKeyboardKey(String key) async {
    if (_currentHost == null || key.isEmpty) return false;
    if (!kIsWeb) {
      _sendUdp('K:$key');
      return true;
    }
    try {
      final response = await _httpClient.post(
        Uri.parse('${_currentHost!.baseUrl}/keyboard'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'key': key}),
      ).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Get PC screen dimensions
  Future<Map<String, int>?> getScreenInfo() async {
    if (_currentHost == null) return null;
    try {
      final response = await _httpClient.get(
        Uri.parse('${_currentHost!.baseUrl}/screen/info'),
      ).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'width': (data['width'] as num).toInt(),
          'height': (data['height'] as num).toInt(),
        };
      }
    } catch (_) {}
    return null;
  }

  /// Fetch a single screen frame (optimized for low latency)
  Future<Uint8List?> fetchScreenFrame({int maxWidth = 854, int quality = 45}) async {
    if (_currentHost == null) return null;
    try {
      final response = await _httpClient.get(
        Uri.parse('${_currentHost!.baseUrl}/screen?max_w=$maxWidth&q=$quality&t=${DateTime.now().millisecondsSinceEpoch}'),
      ).timeout(const Duration(milliseconds: 1200));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return response.bodyBytes;
      }
    } catch (_) {}
    return null;
  }
}
