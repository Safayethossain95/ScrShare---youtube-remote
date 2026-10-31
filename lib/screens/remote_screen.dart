import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../main.dart';
import '../models/host_info.dart';
import '../services/network_discovery_service.dart';
import '../services/remote_client_service.dart';
import '../theme/app_theme.dart';
import '../widgets/dpad_widget.dart';
import '../widgets/top_toast.dart';
import 'pc_remote_screen.dart';

class RemoteScreen extends StatefulWidget {
  final VoidCallback? onSwitchToHost;

  const RemoteScreen({super.key, this.onSwitchToHost});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> with SingleTickerProviderStateMixin {
  final RemoteClientService _client = RemoteClientService();
  bool _isLaunching = false;
  bool _isScanning = false;
  bool _isPlaying = false;
  bool _hasActiveMedia = false;
  double _currentPosition = 0.0;
  double _totalDuration = 0.0;
  bool _isDraggingSeek = false;
  Timer? _mediaTickerTimer;
  List<HostInfo> _discoveredHosts = [];
  StreamSubscription? _connSub;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _mediaTickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_isPlaying && _hasActiveMedia && !_isDraggingSeek) {
        setState(() {
          _currentPosition = (_currentPosition + 1.0).clamp(0.0, _totalDuration);
          if (_currentPosition >= _totalDuration && _totalDuration > 0) {
            _isPlaying = false;
          }
        });
      }
      if (timer.tick % 3 == 0 && _client.isConnected) {
        _syncMediaStatus();
      }
    });

    _initClientAndAutoScan();
  }

  Future<void> _initClientAndAutoScan() async {
    await _client.init();
    _connSub = _client.onConnectionChanged.listen((_) {
      if (mounted) setState(() {});
    });

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    TopToast.hide();
    _pulseController.dispose();
    _mediaTickerTimer?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  Future<void> _syncMediaStatus() async {
    final status = await _client.getMediaStatus();
    if (!mounted || status == null) return;
    final active = status['active'] == true;
    final playing = status['playing'] == true;
    final pos = (status['position'] as num?)?.toDouble() ?? 0.0;
    final dur = (status['duration'] as num?)?.toDouble() ?? 300.0;

    if (active) {
      setState(() {
        _hasActiveMedia = true;
        _isPlaying = playing;
        if (!_isDraggingSeek) {
          _currentPosition = pos;
        }
        if (dur > 0) {
          _totalDuration = dur;
        }
      });
    } else if (!_isPlaying) {
      setState(() {
        _hasActiveMedia = false;
      });
    }
  }

  void _showCustomSnackBar({
    required String message,
    required bool isSuccess,
  }) {
    if (!mounted) return;
    TopToast.show(
      context,
      message: message,
      isSuccess: isSuccess,
    );
  }

  Future<void> _launchUrl(String url, String label) async {
    if (_client.currentHost == null || !_client.isConnected) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      if (_discoveredHosts.isNotEmpty) {
        _showHostPicker(_discoveredHosts, isDark);
      } else {
        await _scanForHosts(showPicker: true);
      }
      if (_client.currentHost == null) {
        _showCustomSnackBar(
          message: 'Please tap a PC to connect first',
          isSuccess: false,
        );
        return;
      }
    }

    setState(() {
      _isLaunching = true;
      _isPlaying = true;
      _hasActiveMedia = true;
      _currentPosition = 0.0;
      _totalDuration = 300.0;
    });

    final success = await _client.launchUrl(url: url);

    if (mounted) {
      setState(() {
        _isLaunching = false;
      });

      if (success) {
        _showCustomSnackBar(
          message: 'Launched $label',
          isSuccess: true,
        );
      } else {
        _showCustomSnackBar(
          message: 'Cannot reach PC',
          isSuccess: false,
        );
      }
    }
  }

  Future<void> _sendAction(String action) async {
    HapticFeedback.lightImpact();
    await _client.sendAction(action);
  }

  Future<void> _performSearch(String query) async {
    HapticFeedback.mediumImpact();
    if (_client.currentHost == null || !_client.isConnected) {
      _showCustomSnackBar(
        message: 'Please connect to a PC first',
        isSuccess: false,
      );
      return;
    }
    setState(() {
      _hasActiveMedia = true;
      _isPlaying = true;
      _currentPosition = 0.0;
      _totalDuration = 300.0;
    });
    _showCustomSnackBar(
      message: 'Searching "$query" on TV',
      isSuccess: true,
    );
    await _client.searchYouTube(query);
  }

  void _openSearchModal(bool isDark) {
    if (_client.currentHost == null || !_client.isConnected) {
      _showCustomSnackBar(
        message: 'Please connect to a PC first',
        isSuccess: false,
      );
      return;
    }

    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final surfaceLightColor = isDark ? AppTheme.darkSurfaceLight : AppTheme.lightSurfaceLight;
    final borderColor = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondaryColor = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    final textController = TextEditingController();
    final focusNode = FocusNode();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: BoxDecoration(
              color: surfaceColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: borderColor, width: 1.5)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: textSecondaryColor.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E676).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: Color(0xFF00E676),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Search YouTube TV',
                        style: GoogleFonts.outfit(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: textPrimaryColor,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, size: 20, color: textSecondaryColor),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: surfaceLightColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: borderColor, width: 1.5),
                  ),
                  child: TextField(
                    controller: textController,
                    focusNode: focusNode,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      color: textPrimaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Type to search on TV...',
                      hintStyle: GoogleFonts.inter(
                        fontSize: 14,
                        color: textSecondaryColor,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        color: textSecondaryColor,
                        size: 22,
                      ),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward_rounded, color: AppTheme.primary),
                        tooltip: 'Search',
                        onPressed: () {
                          final query = textController.text.trim();
                          if (query.isNotEmpty) {
                            Navigator.of(ctx).pop();
                            _performSearch(query);
                          }
                        },
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    onSubmitted: (query) {
                      final trimmed = query.trim();
                      if (trimmed.isNotEmpty) {
                        Navigator.of(ctx).pop();
                        _performSearch(trimmed);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Press Enter on keyboard to search instantly on YouTube TV',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: textSecondaryColor,
                    fontWeight: FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _scanForHosts({bool isSilent = false, bool showPicker = true}) async {
    if (_isScanning) return;

    // Disconnect active host so we can scan fresh and wait for user selection
    _client.disconnect();

    setState(() {
      _isScanning = true;
      _discoveredHosts = [];
    });

    try {
      final hosts = await NetworkDiscoveryService.discoverHosts();
      if (!mounted) return;

      setState(() {
        _discoveredHosts = hosts;
      });

      final isDark = Theme.of(context).brightness == Brightness.dark;

      if (hosts.isNotEmpty) {
        if (showPicker) {
          _showHostPicker(hosts, isDark);
        } else if (!isSilent) {
          _showCustomSnackBar(
            message: 'Found ${hosts.length} ${hosts.length == 1 ? "PC" : "PCs"} on Wi-Fi',
            isSuccess: true,
          );
        }
      } else if (!isSilent) {
        _showCustomSnackBar(
          message: 'No PC found on Wi-Fi',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  void _showHostPicker(List<HostInfo> hosts, bool isDark) {
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final surfaceLightColor = isDark ? AppTheme.darkSurfaceLight : AppTheme.lightSurfaceLight;
    final borderColor = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondaryColor = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Available Computers',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: textPrimaryColor,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, color: AppTheme.primary),
                  tooltip: 'Rescan',
                  onPressed: () {
                    Navigator.pop(ctx);
                    _scanForHosts(showPicker: true);
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Tap your PC to connect:',
              style: GoogleFonts.inter(color: textSecondaryColor, fontSize: 13),
            ),
            const SizedBox(height: 16),
            ...hosts.map((h) => Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: _client.currentHost?.ip == h.ip
                            ? AppTheme.primary
                            : borderColor,
                      ),
                    ),
                    tileColor: surfaceLightColor,
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.laptop_windows_rounded, color: AppTheme.primary, size: 24),
                    ),
                    title: Text(
                      h.name,
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w700, fontSize: 13, color: textPrimaryColor),
                    ),
                    subtitle: Text(
                      'Ready on Wi-Fi (${h.ip})',
                      style: GoogleFonts.inter(fontSize: 11, color: textSecondaryColor),
                    ),
                    trailing: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () {
                        _client.selectHost(h);
                        Navigator.pop(ctx);
                        _showCustomSnackBar(
                          message: 'Connected to ${h.name}',
                          isSuccess: true,
                        );
                        setState(() {});
                      },
                      child: const Text('Connect', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                    onTap: () {
                      _client.selectHost(h);
                      Navigator.pop(ctx);
                      _showCustomSnackBar(
                        message: 'Connected to ${h.name}',
                        isSuccess: true,
                      );
                      setState(() {});
                    },
                  ),
                )),
          ],
        ),
      ),
    );
  }

  void _showManualConnectDialog() {
    final ipController = TextEditingController(text: _client.currentHost?.ip ?? '');
    final portController = TextEditingController(text: '${_client.currentHost?.port ?? 8080}');
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder),
        ),
        title: Row(
          children: [
            const Icon(Icons.settings_ethernet_rounded, color: AppTheme.primary),
            const SizedBox(width: 12),
            Text(
              'Manual IP Entry',
              style: GoogleFonts.outfit(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Optional: Enter IP address if Wi-Fi discovery is restricted.',
              style: GoogleFonts.inter(
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'PC IP Address',
                hintText: 'e.g. 192.168.1.105',
                prefixIcon: Icon(Icons.computer_rounded, size: 20),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '8080',
                prefixIcon: Icon(Icons.numbers_rounded, size: 20),
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final ip = ipController.text.trim();
              final port = int.tryParse(portController.text.trim()) ?? 8080;
              if (ip.isNotEmpty) {
                _client.selectHost(HostInfo(
                  ip: ip,
                  port: port,
                  name: 'PC ($ip)',
                  lastSeen: DateTime.now(),
                ));
                Navigator.pop(ctx);
                setState(() {});
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  void _showCustomUrlDialog() {
    final urlController = TextEditingController(text: 'https://');
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        title: Text('Open Custom URL on PC', style: GoogleFonts.outfit(fontWeight: FontWeight.w700)),
        content: TextField(
          controller: urlController,
          decoration: const InputDecoration(
            hintText: 'https://...',
            prefixIcon: Icon(Icons.link_rounded),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final url = urlController.text.trim();
              if (url.isNotEmpty) {
                Navigator.pop(ctx);
                _launchUrl(url, 'Custom URL');
              }
            },
            child: const Text('Open on PC'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = _client.currentHost;
    final isConnected = _client.isConnected;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppTheme.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.tv_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Text(
              'ScrShare',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.w800,
                fontSize: 20,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        actions: [
          // LIGHT / DARK MODE TOGGLE ICON
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) {
              final isDarkModeActive = mode == ThemeMode.dark;
              return IconButton(
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) => RotationTransition(turns: anim, child: child),
                  child: Icon(
                    isDarkModeActive ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                    key: ValueKey(isDarkModeActive),
                    color: isDarkModeActive ? const Color(0xFFFFD54F) : const Color(0xFF5C6BC0),
                  ),
                ),
                tooltip: isDarkModeActive ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                onPressed: () {
                  themeModeNotifier.value = isDarkModeActive ? ThemeMode.light : ThemeMode.dark;
                },
              );
            },
          ),
          IconButton(
            icon: _isScanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
                  )
                : const Icon(Icons.radar_rounded),
            tooltip: 'Scan Wi-Fi for PC',
            onPressed: _isScanning ? null : () => _scanForHosts(showPicker: true),
          ),
          if (widget.onSwitchToHost != null)
            IconButton(
              icon: const Icon(Icons.laptop_rounded),
              tooltip: 'Switch to PC Host Mode',
              onPressed: widget.onSwitchToHost,
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Connection Status Card
              _buildConnectionBanner(host, isConnected, isDark),

              // 2. Discovered PCs Panel (only show if hosts were found and not connected)
              if (!isConnected && _discoveredHosts.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildDiscoveryPanel(isDark),
              ],

              const SizedBox(height: 24),

              // 3. HERO BUTTON: LAUNCH YOUTUBE TV
              _buildHeroButton(isDark),

              const SizedBox(height: 24),

              // 4. SMART TV NAVIGATION PAD (D-PAD)
              _buildNavigationSection(isDark),

              const SizedBox(height: 24),

              // 5. PLAYBACK & VOLUME CONTROL BAR
              _buildMediaBar(isDark),

              const SizedBox(height: 24),

              // 6. QUICK LAUNCH CHANNELS (NOW POSITIONED BELOW TV REMOTE CONTROL)
              _buildQuickServices(isDark),

              const SizedBox(height: 16),

              // Optional Manual IP link at bottom
              Center(
                child: TextButton.icon(
                  onPressed: _showManualConnectDialog,
                  icon: Icon(
                    Icons.settings_outlined,
                    size: 16,
                    color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                  ),
                  label: Text(
                    'Manual IP Settings (Optional)',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionBanner(HostInfo? host, bool isConnected, bool isDark) {
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final surfaceBorderColor = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final surfaceLightColor = isDark ? AppTheme.darkSurfaceLight : AppTheme.lightSurfaceLight;
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondaryColor = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    Color statusColor = !isConnected
        ? (_isScanning ? AppTheme.warning : AppTheme.error)
        : AppTheme.success;
    String statusTitle = !isConnected
        ? (_isScanning ? 'Scanning Wi-Fi for your PC...' : 'No PC Connected')
        : 'Connected: ${host?.name ?? "PC"}';
    String statusSubtitle = !isConnected
        ? 'Tap to scan and find computers running PC receiver'
        : 'Ready • Tap to switch PC';

    return GestureDetector(
      onTap: () {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        if (_discoveredHosts.isNotEmpty) {
          _showHostPicker(_discoveredHosts, isDark);
        } else {
          _scanForHosts(showPicker: true);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isConnected ? AppTheme.success.withValues(alpha: 0.4) : surfaceBorderColor,
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Status Glowing Orb
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor,
                boxShadow: isConnected
                    ? [
                        BoxShadow(
                          color: AppTheme.success.withValues(alpha: 0.6),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    statusTitle,
                    style: GoogleFonts.outfit(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: textPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    statusSubtitle,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: textSecondaryColor,
                    ),
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: () => _scanForHosts(showPicker: true),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: surfaceLightColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: surfaceBorderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isScanning ? Icons.sync_rounded : Icons.search_rounded,
                      size: 16,
                      color: AppTheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isScanning ? 'Scanning' : 'Scan',
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: AppTheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveryPanel(bool isDark) {
    if (_discoveredHosts.isEmpty) return const SizedBox.shrink();

    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final surfaceLightColor = isDark ? AppTheme.darkSurfaceLight : AppTheme.lightSurfaceLight;
    final surfaceBorderColor = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.devices_rounded, color: AppTheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Found Your PC! Tap to connect:',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: textPrimaryColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._discoveredHosts.map((h) => Material(
                color: surfaceLightColor,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: () {
                    _client.selectHost(h);
                    _showCustomSnackBar(
                      message: 'Connected to ${h.name}',
                      isSuccess: true,
                    );
                    setState(() {});
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: surfaceBorderColor),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.computer_rounded, color: AppTheme.primary, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                h.name,
                                style: GoogleFonts.outfit(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                  color: textPrimaryColor,
                                ),
                              ),
                              Text(
                                'Tap here to connect',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: AppTheme.success,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () {
                            _client.selectHost(h);
                            _showCustomSnackBar(
                              message: 'Connected to ${h.name}',
                              isSuccess: true,
                            );
                            setState(() {});
                          },
                          child: const Text('Connect', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildHeroButton(bool isDark) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final glowAlpha = isDark
            ? (0.35 + (_pulseController.value * 0.25))
            : (0.18 + (_pulseController.value * 0.12));
        final gradientColors = isDark
            ? const [Color(0xFFFF1744), Color(0xFFCC0029)]
            : const [Color(0xFFFF526C), Color(0xFFFF2A55)];

        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: (isDark ? const Color(0xFFFF1744) : const Color(0xFFFF4060))
                    .withValues(alpha: glowAlpha),
                blurRadius: isDark ? 24 : 16,
                spreadRadius: 1,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isLaunching ? null : () => _launchUrl('https://www.youtube.com/tv', 'YouTube TV'),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    colors: gradientColors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _isLaunching
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : const Icon(
                            Icons.play_circle_filled_rounded,
                            size: 30,
                            color: Colors.white,
                          ),
                    const SizedBox(width: 12),
                    Text(
                      'Launch YouTube TV',
                      style: GoogleFonts.outfit(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildNavigationSection(bool isDark) {
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final surfaceLightColor = isDark ? AppTheme.darkSurfaceLight : AppTheme.lightSurfaceLight;
    final surfaceBorderColor = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: surfaceBorderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'TV Remote Control',
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: textPrimaryColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DPadWidget(
            onCommand: _sendAction,
            isEnabled: true,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _buildRemoteIconButton(
                  icon: Icons.arrow_back_rounded,
                  color: AppTheme.primary,
                  tooltip: 'Back (Backspace)',
                  borderColor: surfaceBorderColor,
                  bgColor: surfaceLightColor,
                  onPressed: () => _sendAction('back'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildRemoteIconButton(
                  icon: Icons.search_rounded,
                  color: const Color(0xFF00E676),
                  tooltip: 'Search YouTube TV',
                  borderColor: surfaceBorderColor,
                  bgColor: surfaceLightColor,
                  onPressed: () => _openSearchModal(isDark),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildRemoteIconButton(
                  icon: Icons.fullscreen_rounded,
                  color: AppTheme.accent,
                  tooltip: 'Fullscreen (F11)',
                  borderColor: surfaceBorderColor,
                  bgColor: surfaceLightColor,
                  onPressed: () => _sendAction('fullscreen'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteIconButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required Color borderColor,
    required Color bgColor,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onPressed();
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, color: color, size: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildMediaBar(bool isDark) {
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final surfaceBorderColor = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final textSecondaryColor = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    final showSeekBar = (_hasActiveMedia || _isPlaying) && _totalDuration > 0;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: showSeekBar ? 16 : 12),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: surfaceBorderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Upper Seek Bar: Live seeking for the running video (hidden if no video playing)
          if (showSeekBar) ...[
            _buildLiveSeekBar(isDark, textPrimaryColor, textSecondaryColor),
            const SizedBox(height: 12),
          ],

          // Playback & Volume Control Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildActionButton(
                icon: Icons.volume_mute_rounded,
                tooltip: 'Mute',
                color: textSecondaryColor,
                onPressed: () => _sendAction('mute'),
              ),
              _buildActionButton(
                icon: Icons.volume_down_rounded,
                tooltip: 'Volume -',
                color: textSecondaryColor,
                onPressed: () => _sendAction('volume_down'),
              ),
              Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.primary,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primaryGlow,
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  tooltip: _isPlaying ? 'Pause (Space)' : 'Play (Space)',
                  onPressed: () {
                    setState(() {
                      _isPlaying = !_isPlaying;
                      if (_isPlaying && !_hasActiveMedia) {
                        _hasActiveMedia = true;
                        if (_totalDuration <= 0) _totalDuration = 300.0;
                      }
                    });
                    _sendAction('play_pause');
                  },
                ),
              ),
              _buildActionButton(
                icon: Icons.volume_up_rounded,
                tooltip: 'Volume +',
                color: textSecondaryColor,
                onPressed: () => _sendAction('volume_up'),
              ),
              _buildActionButton(
                icon: Icons.fullscreen_rounded,
                tooltip: 'Fullscreen (F11)',
                color: textSecondaryColor,
                onPressed: () => _sendAction('fullscreen'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLiveSeekBar(bool isDark, Color textPrimaryColor, Color textSecondaryColor) {
    final curPos = _currentPosition.clamp(0.0, _totalDuration);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isPlaying ? const Color(0xFF00E676) : textSecondaryColor,
                      boxShadow: _isPlaying
                          ? [
                              const BoxShadow(
                                color: Color(0xFF00E676),
                                blurRadius: 6,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _formatDuration(curPos),
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textPrimaryColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              Text(
                _formatDuration(_totalDuration),
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: textSecondaryColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: AppTheme.primary,
            inactiveTrackColor: isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.08),
            thumbColor: Colors.white,
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 7,
              elevation: 4,
              pressedElevation: 6,
            ),
            overlayColor: AppTheme.primary.withValues(alpha: 0.2),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: curPos,
            min: 0.0,
            max: _totalDuration > 0 ? _totalDuration : 1.0,
            onChangeStart: (val) {
              _isDraggingSeek = true;
            },
            onChanged: (val) {
              setState(() {
                _currentPosition = val;
              });
            },
            onChangeEnd: (val) {
              _isDraggingSeek = false;
              _onSeekVideo(val);
            },
          ),
        ),
      ],
    );
  }

  String _formatDuration(double seconds) {
    final s = seconds.toInt();
    final m = s ~/ 60;
    final remainingS = s % 60;
    final h = m ~/ 60;
    final remainingM = m % 60;

    if (h > 0) {
      return '$h:${remainingM.toString().padLeft(2, '0')}:${remainingS.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${remainingS.toString().padLeft(2, '0')}';
  }

  void _onSeekVideo(double newPosition) {
    HapticFeedback.selectionClick();
    final ratio = _totalDuration > 0 ? (newPosition / _totalDuration).clamp(0.0, 1.0) : 0.0;
    _client.seekMedia(ratio: ratio, position: newPosition);
  }

  // Quick launch channels placed below TV Remote Control
  Widget _buildQuickServices(bool isDark) {
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Launch Channels',
          style: GoogleFonts.outfit(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: textPrimaryColor,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildServiceCard(
                title: 'YouTube TV',
                url: 'https://www.youtube.com/tv',
                icon: Icons.smart_display_rounded,
                color: const Color(0xFFFF5252),
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildServiceCard(
                title: 'PC Remote',
                url: '',
                icon: Icons.mouse_rounded,
                color: const Color(0xFF00E676),
                isPcRemote: true,
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildServiceCard(
                title: 'Custom URL',
                url: '',
                icon: Icons.open_in_browser_rounded,
                color: const Color(0xFF448AFF),
                isCustom: true,
                isDark: isDark,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildServiceCard({
    required String title,
    required String url,
    required IconData icon,
    required Color color,
    required bool isDark,
    bool isCustom = false,
    bool isPcRemote = false,
  }) {
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final surfaceBorderColor = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Material(
      color: surfaceColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () {
          if (isPcRemote) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const PcRemoteScreen()),
            );
          } else if (isCustom) {
            _showCustomUrlDialog();
          } else {
            _launchUrl(url, title);
          }
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: surfaceBorderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: textPrimaryColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, color: color, size: 24),
      tooltip: tooltip,
      splashRadius: 22,
      onPressed: onPressed,
    );
  }
}
