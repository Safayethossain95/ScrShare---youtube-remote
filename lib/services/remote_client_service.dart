import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/host_info.dart';

class RemoteClientService {
  static final RemoteClientService _instance = RemoteClientService._internal();
  factory RemoteClientService() => _instance;
  RemoteClientService._internal();

  HostInfo? _currentHost;
  HostInfo? get currentHost => _currentHost;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  final StreamController<bool> _connectionStateController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionChanged => _connectionStateController.stream;

  static const String keyLastHostIp = 'last_host_ip';
  static const String keyLastHostPort = 'last_host_port';
  static const String keyLastHostName = 'last_host_name';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(keyLastHostIp);
    final port = prefs.getInt(keyLastHostPort) ?? 8080;
    final name = prefs.getString(keyLastHostName) ?? 'Saved PC';

    if (ip != null && ip.isNotEmpty) {
      _currentHost = HostInfo(
        ip: ip,
        port: port,
        name: name,
        lastSeen: DateTime.now(),
      );
      // Verify connection in background
      checkConnection();
    }
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

  /// Send navigation or playback action to the PC
  Future<bool> sendAction(String command) async {
    if (_currentHost == null) return false;

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
}
