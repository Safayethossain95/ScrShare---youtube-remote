import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../main.dart';
import '../services/pc_host_service.dart';
import '../theme/app_theme.dart';

class HostScreen extends StatefulWidget {
  final VoidCallback onSwitchToRemote;

  const HostScreen({super.key, required this.onSwitchToRemote});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  final PCHostService _hostService = PCHostService();
  StreamSubscription<LogEvent>? _logSub;
  String _ipAddress = 'Detecting...';

  @override
  void initState() {
    super.initState();
    _startHost();
  }

  Future<void> _startHost() async {
    await _hostService.startServer();
    final ip = await _hostService.getLocalIp();

    _logSub = _hostService.onLog.listen((_) {
      if (mounted) setState(() {});
    });

    if (mounted) {
      setState(() {
        _ipAddress = ip;
      });
    }
  }

  @override
  void dispose() {
    _logSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final qrData = 'http://$_ipAddress:${_hostService.port}';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppTheme.surfaceLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.primary, width: 1.5),
              ),
              child: const Icon(Icons.desktop_windows_rounded, color: AppTheme.primary, size: 20),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'ScrShare Host Hub',
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) {
              final isDarkModeActive = mode == ThemeMode.dark;
              return IconButton(
                icon: Icon(
                  isDarkModeActive ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  color: isDarkModeActive ? const Color(0xFFFFD54F) : const Color(0xFF5C6BC0),
                ),
                tooltip: isDarkModeActive ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                onPressed: () {
                  themeModeNotifier.value = isDarkModeActive ? ThemeMode.light : ThemeMode.dark;
                },
              );
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.settings_remote_rounded, color: AppTheme.primary, size: 18),
            label: const Text('Remote Mode', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w700)),
            onPressed: widget.onSwitchToRemote,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktopWidth = constraints.maxWidth >= 850;

            if (isDesktopWidth) {
              return Padding(
                padding: const EdgeInsets.all(24.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 4,
                      child: SingleChildScrollView(
                        child: _buildControlsColumn(qrData),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 5,
                      child: _buildActivityLogBox(),
                    ),
                  ],
                ),
              );
            } else {
              // Narrow/mobile responsive layout
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildControlsColumn(qrData),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 380,
                      child: _buildActivityLogBox(),
                    ),
                  ],
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildControlsColumn(String qrData) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Status Box
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _hostService.isRunning ? AppTheme.success : AppTheme.error,
                      boxShadow: _hostService.isRunning
                          ? [
                              BoxShadow(
                                color: AppTheme.success.withValues(alpha: 0.6),
                                blurRadius: 10,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _hostService.isRunning ? 'PC Receiver Ready' : 'Server Stopped',
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Listening for Wi-Fi commands at:',
                style: GoogleFonts.inter(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 4),
              SelectableText(
                'http://$_ipAddress:${_hostService.port}',
                style: GoogleFonts.outfit(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // QR Code Card for phone pairing
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Column(
            children: [
              Text(
                'Scan from Phone or Enter IP',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Make sure your phone is on the same Wi-Fi',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: 150.0,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                children: [
                  const Icon(Icons.wifi_rounded, size: 16, color: AppTheme.success),
                  Text(
                    'UDP Discovery Active (Port 8088)',
                    style: GoogleFonts.inter(fontSize: 11, color: AppTheme.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // Local Test Button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.surfaceLight,
            foregroundColor: AppTheme.textPrimary,
            side: const BorderSide(color: AppTheme.surfaceBorder),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          icon: const Icon(Icons.play_circle_filled_rounded, color: AppTheme.primary),
          label: const Text('Test Open YouTube TV on this PC'),
          onPressed: () {
            _hostService.launchUrlOnHost('https://tv.youtube.com');
          },
        ),
      ],
    );
  }

  Widget _buildActivityLogBox() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.receipt_long_rounded, color: AppTheme.textSecondary, size: 20),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Live Activity Log',
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${_hostService.logs.length} events',
                  style: GoogleFonts.inter(fontSize: 12, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.surfaceBorder),

          // Log list
          Expanded(
            child: _hostService.logs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.hourglass_empty_rounded, size: 40, color: AppTheme.textMuted),
                        const SizedBox(height: 12),
                        Text(
                          'Waiting for commands from mobile remote...',
                          style: GoogleFonts.inter(color: AppTheme.textMuted, fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _hostService.logs.length,
                    itemBuilder: (ctx, i) {
                      final log = _hostService.logs[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceLight,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: log.isSuccess
                                ? AppTheme.surfaceBorder
                                : AppTheme.error.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              log.isSuccess ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                              size: 18,
                              color: log.isSuccess ? AppTheme.success : AppTheme.error,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    log.title,
                                    style: GoogleFonts.outfit(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    log.detail,
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
