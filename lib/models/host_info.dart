class HostInfo {
  final String ip;
  final int port;
  final String name;
  final String os;
  final DateTime lastSeen;
  final bool isAutoDiscovered;

  const HostInfo({
    required this.ip,
    required this.port,
    required this.name,
    this.os = 'Windows',
    required this.lastSeen,
    this.isAutoDiscovered = false,
  });

  String get baseUrl => 'http://$ip:$port';

  Map<String, dynamic> toJson() => {
    'ip': ip,
    'port': port,
    'name': name,
    'os': os,
    'lastSeen': lastSeen.toIso8601String(),
    'isAutoDiscovered': isAutoDiscovered,
  };

  factory HostInfo.fromJson(Map<String, dynamic> json) {
    return HostInfo(
      ip: json['ip'] as String? ?? '127.0.0.1',
      port: json['port'] as int? ?? 8080,
      name: json['name'] as String? ?? 'PC Host',
      os: json['os'] as String? ?? 'Windows',
      lastSeen: json['lastSeen'] != null 
          ? DateTime.tryParse(json['lastSeen'] as String) ?? DateTime.now() 
          : DateTime.now(),
      isAutoDiscovered: json['isAutoDiscovered'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HostInfo &&
          runtimeType == other.runtimeType &&
          ip == other.ip &&
          port == other.port;

  @override
  int get hashCode => ip.hashCode ^ port.hashCode;
}
