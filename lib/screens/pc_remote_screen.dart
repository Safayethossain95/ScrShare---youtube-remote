import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/remote_client_service.dart';
import '../theme/app_theme.dart';

enum PcRemoteMode {
  trackpad,
  mirror,
}

class PcRemoteScreen extends StatefulWidget {
  const PcRemoteScreen({super.key});

  @override
  State<PcRemoteScreen> createState() => _PcRemoteScreenState();
}

class _PcRemoteScreenState extends State<PcRemoteScreen> {
  final RemoteClientService _remoteService = RemoteClientService();

  PcRemoteMode _mode = PcRemoteMode.trackpad;
  bool _isKeyboardOpen = false;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _keyboardFocusNode = FocusNode();

  // Screen Mirroring State
  Uint8List? _currentFrame;
  bool _isFetchingFrame = false;
  bool _isMirrorActive = false;
  bool _isFullScreenMirror = false;
  Timer? _mirrorTimer;
  int _fpsCount = 0;
  int _currentFps = 0;
  Timer? _fpsTimer;


  // Trackpad Sensitivity & Dragging
  double _sensitivity = 1.35;
  bool _isLeftButtonDown = false;
  bool _isRightButtonDown = false;

  // Low-latency Trackpad raw pointer tracking
  final Map<int, Offset> _tpPointers = {};
  DateTime? _tpDownTime;
  double _tpTotalDist = 0.0;
  int _tpMaxPointers = 0;
  DateTime? _tpLastTapTime;

  // Mirror mode raw pointer tracking
  final Map<int, Offset> _mirrorActivePointers = {};
  DateTime? _mirrorFirstPointerDownTime;
  double _mirrorTotalDist = 0.0;
  int _mirrorMaxPointers = 0;
  DateTime? _mirrorLastTapTime;

  // Ultra Low Latency Stream Presets
  int _mirrorMaxWidth = 854; // 854 (Ultra Fast) or 1280 (HD)
  int _mirrorQuality = 42;   // 42 (Low Latency) or 65 (HD)
  bool _isUltraFastMode = true;



  StreamSubscription<bool>? _connSub;

  @override
  void initState() {
    super.initState();
    _connSub = _remoteService.onConnectionChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _initPcRemote();
  }

  Future<void> _initPcRemote() async {
    await _remoteService.getScreenInfo();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    if (_isFullScreenMirror) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _stopMirrorStream();
    _textController.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _startMirrorStream() {
    _isMirrorActive = true;
    _fpsCount = 0;
    _fpsTimer?.cancel();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentFps = _fpsCount;
          _fpsCount = 0;
        });
      }
    });
    _fetchNextFrameLoop();
  }

  void _stopMirrorStream() {
    _isMirrorActive = false;
    _mirrorTimer?.cancel();
    _fpsTimer?.cancel();
  }

  Future<void> _fetchNextFrameLoop() async {
    if (!_isMirrorActive || !mounted) return;
    if (_isFetchingFrame) return;

    _isFetchingFrame = true;
    try {
      final frame = await _remoteService.fetchScreenFrame(
        maxWidth: _mirrorMaxWidth,
        quality: _mirrorQuality,
      );
      if (frame != null && mounted) {
        setState(() {
          _currentFrame = frame;
          _fpsCount++;
        });
      }
    } catch (_) {} finally {
      _isFetchingFrame = false;
    }

    if (_isMirrorActive && mounted) {
      // Immediate 0ms schedule for maximum responsiveness and high FPS!
      _mirrorTimer = Timer(Duration.zero, _fetchNextFrameLoop);
    }
  }

  void _toggleMode(PcRemoteMode newMode) {
    HapticFeedback.mediumImpact();
    setState(() {
      _mode = newMode;
      if (_mode == PcRemoteMode.mirror) {
        _startMirrorStream();
      } else {
        if (_isFullScreenMirror) {
          _isFullScreenMirror = false;
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }
        _stopMirrorStream();
      }
    });
  }

  void _toggleFullScreenMirror() {
    HapticFeedback.mediumImpact();
    setState(() {
      _isFullScreenMirror = !_isFullScreenMirror;
      if (_isFullScreenMirror) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    });
  }

  void _toggleKeyboard() {
    HapticFeedback.lightImpact();
    setState(() {
      _isKeyboardOpen = !_isKeyboardOpen;
    });

    if (_isKeyboardOpen) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _keyboardFocusNode.requestFocus();
      });
    } else {
      _keyboardFocusNode.unfocus();
    }
  }

  void _onKeyAction(String keyName) {
    HapticFeedback.selectionClick();
    _remoteService.sendKeyboardKey(keyName);
  }

  void _onTextSubmitted(String value) {
    if (value.isNotEmpty) {
      _remoteService.sendKeyboardText(value);
      _textController.clear();
    }
  }

  // ==================== TRACKPAD LOW-LEVEL LISTENER ====================
  void _onTrackpadPointerDown(PointerDownEvent event) {
    _tpPointers[event.pointer] = event.position;
    if (_tpPointers.length == 1) {
      _tpDownTime = DateTime.now();
      _tpTotalDist = 0.0;
      _tpMaxPointers = 1;
    } else if (_tpPointers.length > _tpMaxPointers) {
      _tpMaxPointers = _tpPointers.length;
    }
  }

  void _onTrackpadPointerMove(PointerMoveEvent event) {
    if (_tpPointers.length == 1) {
      final dx = event.delta.dx * _sensitivity;
      final dy = event.delta.dy * _sensitivity;
      _tpTotalDist += event.delta.distance;
      // Instant zero-allocation binary UDP packet: 0ms latency, zero GC!
      _remoteService.sendRawPointerMove(dx, dy);
    } else if (_tpPointers.length == 2) {
      // Two-finger smooth scrolling
      if (event.delta.dy.abs() > 0.4) {
        final scrollDelta = (event.delta.dy * -6).toInt();
        _remoteService.sendMouseScroll(scrollDelta);
      }
    }
  }

  void _onTrackpadPointerUp(PointerUpEvent event) {
    _tpPointers.remove(event.pointer);
    if (_tpPointers.isEmpty) {
      final elapsed = DateTime.now().difference(_tpDownTime ?? DateTime.now()).inMilliseconds;
      if (_tpTotalDist < 10.0 && elapsed < 260) {
        if (_tpMaxPointers == 1) {
          final now = DateTime.now();
          if (_tpLastTapTime != null && now.difference(_tpLastTapTime!).inMilliseconds < 280) {
            HapticFeedback.mediumImpact();
            _remoteService.sendMouseClick('double');
            _tpLastTapTime = null;
          } else {
            HapticFeedback.lightImpact();
            _remoteService.sendMouseClick('left');
            _tpLastTapTime = now;
          }
        } else if (_tpMaxPointers == 2) {
          HapticFeedback.mediumImpact();
          _remoteService.sendMouseClick('right');
        }
      }
      _tpMaxPointers = 0;
      _tpTotalDist = 0.0;
    }
  }

  void _onTrackpadPointerCancel(PointerCancelEvent event) {
    _tpPointers.remove(event.pointer);
    if (_tpPointers.isEmpty) {
      _tpMaxPointers = 0;
      _tpTotalDist = 0.0;
    }
  }

  // ==================== MIRROR LOW-LEVEL LISTENER ====================
  Widget _buildInteractiveMirrorView() {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _mirrorActivePointers[event.pointer] = event.position;
        if (_mirrorActivePointers.length == 1) {
          _mirrorFirstPointerDownTime = DateTime.now();
          _mirrorMaxPointers = 1;
          _mirrorTotalDist = 0.0;
        } else if (_mirrorActivePointers.length > _mirrorMaxPointers) {
          _mirrorMaxPointers = _mirrorActivePointers.length;
        }
      },
      onPointerMove: (event) {
        if (_mirrorActivePointers.length == 1) {
          final dx = event.delta.dx * _sensitivity;
          final dy = event.delta.dy * _sensitivity;
          _mirrorTotalDist += event.delta.distance;
          // Instant direct UDP move
          _remoteService.sendRawPointerMove(dx, dy);
        } else if (_mirrorActivePointers.length == 2 && event.delta.dy.abs() > 0.4) {
          final scrollDelta = (event.delta.dy * -6).toInt();
          _remoteService.sendMouseScroll(scrollDelta);
        }
      },
      onPointerUp: (event) {
        _mirrorActivePointers.remove(event.pointer);
        if (_mirrorActivePointers.isEmpty) {
          final elapsed = DateTime.now().difference(_mirrorFirstPointerDownTime ?? DateTime.now()).inMilliseconds;
          if (_mirrorTotalDist < 12.0 && elapsed < 260) {
            if (_mirrorMaxPointers == 2) {
              // Two-finger tap -> Right Click!
              HapticFeedback.mediumImpact();
              _remoteService.sendMouseClick('right');
            } else if (_mirrorMaxPointers == 1) {
              // Double tap check -> Left Click
              final now = DateTime.now();
              if (_mirrorLastTapTime != null && now.difference(_mirrorLastTapTime!).inMilliseconds < 300) {
                HapticFeedback.lightImpact();
                _remoteService.sendMouseClick('left');
                _mirrorLastTapTime = null;
              } else {
                _mirrorLastTapTime = now;
              }
            }
          }
          _mirrorMaxPointers = 0;
          _mirrorTotalDist = 0.0;
        }
      },
      onPointerCancel: (event) {
        _mirrorActivePointers.remove(event.pointer);
        if (_mirrorActivePointers.isEmpty) {
          _mirrorMaxPointers = 0;
          _mirrorTotalDist = 0.0;
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_currentFrame != null)
            Image.memory(
              _currentFrame!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Color(0xFF00E676)),
                  const SizedBox(height: 16),
                  Text(
                    'Connecting to PC Screen...',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Glide finger to move • Double tap to left click',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final surfaceBorderColor = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final textPrimaryColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondaryColor = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    final host = _remoteService.currentHost;

    if (_mode == PcRemoteMode.mirror && _isFullScreenMirror) {
      return _buildFullscreenMirrorScaffold(isDark, surfaceColor, surfaceBorderColor, textPrimaryColor, textSecondaryColor);
    }

    return Scaffold(
      backgroundColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      appBar: AppBar(
        backgroundColor: surfaceColor,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: textPrimaryColor,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PC Remote Controller',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: textPrimaryColor,
              ),
            ),
            if (host != null)
              Text(
                '${host.name} (${host.ip})',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: textSecondaryColor,
                ),
              ),
          ],
        ),
        actions: [
          // Keyboard Button
          IconButton(
            tooltip: 'Toggle Keyboard',
            icon: Icon(
              Icons.keyboard_rounded,
              color: _isKeyboardOpen ? const Color(0xFF448AFF) : textPrimaryColor,
            ),
            onPressed: _toggleKeyboard,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Top Mode Switch Bar & Helper Indicator
            _buildTopModeBar(isDark, surfaceColor, surfaceBorderColor, textPrimaryColor),

            // Main Workspace (Trackpad or Screen Mirror)
            Expanded(
              child: _mode == PcRemoteMode.trackpad
                  ? _buildTrackpadArea(isDark, surfaceColor, surfaceBorderColor, textPrimaryColor, textSecondaryColor)
                  : _buildMirrorArea(isDark, surfaceColor, surfaceBorderColor, textPrimaryColor, textSecondaryColor),
            ),

            // Bottom Mouse Buttons (Left Click & Right Click) - Only in Touch Mouse mode
            if (_mode == PcRemoteMode.trackpad)
              _buildMouseButtonsRow(isDark, surfaceColor, surfaceBorderColor, textPrimaryColor),

            // Keyboard Drawer / Input Bar (Shown if toggled)
            if (_isKeyboardOpen)
              _buildKeyboardPanel(isDark, surfaceColor, surfaceBorderColor, textPrimaryColor, textSecondaryColor),
          ],
        ),
      ),
    );
  }

  // ==================== TOP MODE BAR ====================
  Widget _buildTopModeBar(bool isDark, Color surfaceColor, Color borderColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: surfaceColor,
        border: Border(bottom: BorderSide(color: borderColor, width: 1)),
      ),
      child: Row(
        children: [
          // Trackpad Mode Chip
          Expanded(
            child: InkWell(
              onTap: () => _toggleMode(PcRemoteMode.trackpad),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _mode == PcRemoteMode.trackpad
                      ? const Color(0xFF448AFF).withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _mode == PcRemoteMode.trackpad
                        ? const Color(0xFF448AFF)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.touch_app_rounded,
                      size: 18,
                      color: _mode == PcRemoteMode.trackpad ? const Color(0xFF448AFF) : textColor.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Touch Mouse',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        fontWeight: _mode == PcRemoteMode.trackpad ? FontWeight.w700 : FontWeight.w500,
                        color: _mode == PcRemoteMode.trackpad ? const Color(0xFF448AFF) : textColor.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Screen Mirror Mode Chip
          Expanded(
            child: InkWell(
              onTap: () => _toggleMode(PcRemoteMode.mirror),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _mode == PcRemoteMode.mirror
                      ? const Color(0xFF00E676).withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _mode == PcRemoteMode.mirror
                        ? const Color(0xFF00E676)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.screen_share_rounded,
                      size: 18,
                      color: _mode == PcRemoteMode.mirror ? const Color(0xFF00E676) : textColor.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Mirror PC Screen',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        fontWeight: _mode == PcRemoteMode.mirror ? FontWeight.w700 : FontWeight.w500,
                        color: _mode == PcRemoteMode.mirror ? const Color(0xFF00E676) : textColor.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== TRACKPAD (FULL SCREEN MOUSE) ====================
  Widget _buildTrackpadArea(bool isDark, Color surfaceColor, Color borderColor, Color textColor, Color mutedColor) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Material(
        color: isDark ? const Color(0xFF141724) : Colors.white,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: borderColor, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.05),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onTrackpadPointerDown,
              onPointerMove: _onTrackpadPointerMove,
              onPointerUp: _onTrackpadPointerUp,
              onPointerCancel: _onTrackpadPointerCancel,
              child: Stack(
                children: [
                  // Subtle Trackpad Grid Design / Pattern
                  Center(
                    child: Opacity(
                      opacity: isDark ? 0.07 : 0.04,
                      child: Icon(
                        Icons.mouse_rounded,
                        size: 180,
                        color: textColor,
                      ),
                    ),
                  ),

                  // Gesture Hints
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: surfaceColor.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: borderColor.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.touch_app_rounded, size: 14, color: mutedColor),
                            const SizedBox(width: 6),
                            Text(
                              'Tap to click • two finger tap to right click',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w500, 
                                color: mutedColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Sensitivity Control Slider Pill at Top Right
                  Positioned(
                    top: 14,
                    right: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: surfaceColor.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: borderColor),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.speed_rounded, size: 14, color: mutedColor),
                          const SizedBox(width: 4),
                          Text(
                            'Speed: ${_sensitivity.toStringAsFixed(1)}x',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: () {
                              setState(() {
                                _sensitivity = _sensitivity >= 2.5 ? 0.8 : _sensitivity + 0.4;
                              });
                              HapticFeedback.selectionClick();
                            },
                            child: const Icon(Icons.add_circle_outline_rounded, size: 16, color: Color(0xFF448AFF)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== SCREEN MIRROR AREA ====================
  Widget _buildMirrorArea(bool isDark, Color surfaceColor, Color borderColor, Color textColor, Color mutedColor) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          // Live Stats & Refresh Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E676).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF00E676),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'LIVE MIRROR ${_currentFps > 0 ? '• $_currentFps FPS' : ''}',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF00E676),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              // Ultra Fast / HD Quality Preset Toggle
              InkWell(
                onTap: () {
                  setState(() {
                    _isUltraFastMode = !_isUltraFastMode;
                    if (_isUltraFastMode) {
                      _mirrorMaxWidth = 854;
                      _mirrorQuality = 42;
                    } else {
                      _mirrorMaxWidth = 1280;
                      _mirrorQuality = 65;
                    }
                  });
                  HapticFeedback.selectionClick();
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _isUltraFastMode
                        ? const Color(0xFF00E676).withValues(alpha: 0.15)
                        : const Color(0xFF448AFF).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _isUltraFastMode ? const Color(0xFF00E676) : const Color(0xFF448AFF),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isUltraFastMode ? Icons.bolt_rounded : Icons.high_quality_rounded,
                        size: 13,
                        color: _isUltraFastMode ? const Color(0xFF00E676) : const Color(0xFF448AFF),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _isUltraFastMode ? 'Ultra Fast' : 'HD Quality',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: _isUltraFastMode ? const Color(0xFF00E676) : const Color(0xFF448AFF),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.fullscreen_rounded, size: 24),
                tooltip: 'Fullscreen on Phone',
                color: const Color(0xFF00E676),
                onPressed: _toggleFullScreenMirror,
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'Refresh Screen',
                color: textColor,
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _fetchNextFrameLoop();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Interactive Mirrored Display Box
          Expanded(
            child: Material(
              color: Colors.black,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: borderColor, width: 1.5),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildInteractiveMirrorView(),

                    // Touch Gesture Guidance Overlay Badge
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.touch_app_rounded, size: 12, color: Color(0xFF00E676)),
                            const SizedBox(width: 6),
                            Text(
                              'Trackpad: Glide = Move • 2x Tap = Left Click • 2 Fingers = Right Click',
                              style: GoogleFonts.inter(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Fullscreen Button Overlay in Corner of Display
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _toggleFullScreenMirror,
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.75),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white24),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.fullscreen_rounded, size: 16, color: Color(0xFF00E676)),
                                const SizedBox(width: 4),
                                Text(
                                  'Fullscreen',
                                  style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== MOUSE BUTTONS (LEFT & RIGHT CLICK) ====================
  Widget _buildMouseButtonsRow(bool isDark, Color surfaceColor, Color borderColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: surfaceColor,
        border: Border(top: BorderSide(color: borderColor, width: 1)),
      ),
      child: Row(
        children: [
          // Left Click Button
          Expanded(
            flex: 5,
            child: GestureDetector(
              onTapDown: (_) {
                setState(() => _isLeftButtonDown = true);
                HapticFeedback.lightImpact();
                _remoteService.sendMouseDown('left');
              },
              onTapUp: (_) {
                setState(() => _isLeftButtonDown = false);
                _remoteService.sendMouseUp('left');
              },
              onTapCancel: () {
                setState(() => _isLeftButtonDown = false);
                _remoteService.sendMouseUp('left');
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                height: 54,
                decoration: BoxDecoration(
                  color: _isLeftButtonDown
                      ? const Color(0xFF448AFF)
                      : (isDark ? const Color(0xFF1D2232) : const Color(0xFFEEF2F7)),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isLeftButtonDown ? const Color(0xFF448AFF) : borderColor,
                    width: 1.5,
                  ),
                  boxShadow: [
                    if (!_isLeftButtonDown)
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.mouse_rounded,
                      size: 20,
                      color: _isLeftButtonDown ? Colors.white : textColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'LEFT CLICK',
                      style: GoogleFonts.outfit(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _isLeftButtonDown ? Colors.white : textColor,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Scroll Strip Wheel in Center
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: GestureDetector(
              onVerticalDragUpdate: (details) {
                // Scroll wheel delta
                final delta = (details.primaryDelta ?? 0) * -15;
                _remoteService.sendMouseScroll(delta.toInt());
              },
              child: Container(
                width: 44,
                height: 54,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF191D2B) : const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.unfold_more_rounded, size: 20, color: textColor.withValues(alpha: 0.7)),
                    Text(
                      'Scroll',
                      style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w600, color: textColor.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Right Click Button
          Expanded(
            flex: 5,
            child: GestureDetector(
              onTapDown: (_) {
                setState(() => _isRightButtonDown = true);
                HapticFeedback.lightImpact();
                _remoteService.sendMouseDown('right');
              },
              onTapUp: (_) {
                setState(() => _isRightButtonDown = false);
                _remoteService.sendMouseUp('right');
              },
              onTapCancel: () {
                setState(() => _isRightButtonDown = false);
                _remoteService.sendMouseUp('right');
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                height: 54,
                decoration: BoxDecoration(
                  color: _isRightButtonDown
                      ? const Color(0xFFFF5252)
                      : (isDark ? const Color(0xFF1D2232) : const Color(0xFFEEF2F7)),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isRightButtonDown ? const Color(0xFFFF5252) : borderColor,
                    width: 1.5,
                  ),
                  boxShadow: [
                    if (!_isRightButtonDown)
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.menu_rounded,
                      size: 18,
                      color: _isRightButtonDown ? Colors.white : textColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'RIGHT CLICK',
                      style: GoogleFonts.outfit(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _isRightButtonDown ? Colors.white : textColor,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== KEYBOARD PANEL ====================
  Widget _buildKeyboardPanel(bool isDark, Color surfaceColor, Color borderColor, Color textColor, Color mutedColor) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(
        color: surfaceColor,
        border: Border(top: BorderSide(color: borderColor, width: 1.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Live Typing Text Field
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  focusNode: _keyboardFocusNode,
                  style: GoogleFonts.inter(fontSize: 14, color: textColor),
                  decoration: InputDecoration(
                    hintText: 'Type text here to send to PC...',
                    hintStyle: GoogleFonts.inter(fontSize: 13, color: mutedColor),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0C0D12) : const Color(0xFFF1F5F9),
                  ),
                  onSubmitted: _onTextSubmitted,
                  textInputAction: TextInputAction.send,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.send_rounded, size: 18),
                onPressed: () => _onTextSubmitted(_textController.text),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_hide_rounded, size: 20),
                tooltip: 'Close Keyboard',
                onPressed: _toggleKeyboard,
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Shortcut Buttons Row 1: Common Control Keys
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildKeyButton('Esc', 'escape', isDark, borderColor, textColor),
                _buildKeyButton('Tab', 'tab', isDark, borderColor, textColor),
                _buildKeyButton('Win', 'win', isDark, borderColor, textColor),
                _buildKeyButton('Ctrl', 'ctrl', isDark, borderColor, textColor),
                _buildKeyButton('Alt', 'alt', isDark, borderColor, textColor),
                _buildKeyButton('Shift', 'shift', isDark, borderColor, textColor),
                _buildKeyButton('Del', 'delete', isDark, borderColor, textColor),
                _buildKeyButton('Backspace', 'backspace', isDark, borderColor, textColor, isAccent: true),
                _buildKeyButton('Enter', 'enter', isDark, borderColor, textColor, isPrimary: true),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Shortcut Buttons Row 2: Windows Shortcuts & Navigation
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildKeyButton('Ctrl+C', 'ctrl+c', isDark, borderColor, textColor),
                _buildKeyButton('Ctrl+V', 'ctrl+v', isDark, borderColor, textColor),
                _buildKeyButton('Ctrl+Z', 'ctrl+z', isDark, borderColor, textColor),
                _buildKeyButton('Ctrl+A', 'ctrl+a', isDark, borderColor, textColor),
                _buildKeyButton('Win+D', 'win+d', isDark, borderColor, textColor),
                _buildKeyButton('Alt+Tab', 'alt+tab', isDark, borderColor, textColor),
                _buildKeyButton('F5 (Refresh)', 'f5', isDark, borderColor, textColor),
                _buildKeyButton('F11 (Full)', 'f11', isDark, borderColor, textColor),
                _buildKeyButton('←', 'left', isDark, borderColor, textColor),
                _buildKeyButton('↑', 'up', isDark, borderColor, textColor),
                _buildKeyButton('↓', 'down', isDark, borderColor, textColor),
                _buildKeyButton('→', 'right', isDark, borderColor, textColor),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyButton(
    String label,
    String action,
    bool isDark,
    Color borderColor,
    Color textColor, {
    bool isPrimary = false,
    bool isAccent = false,
  }) {
    Color bg = isDark ? const Color(0xFF1D2232) : const Color(0xFFEEF2F7);
    Color fg = textColor;

    if (isPrimary) {
      bg = const Color(0xFF448AFF);
      fg = Colors.white;
    } else if (isAccent) {
      bg = const Color(0xFFFF5252).withValues(alpha: 0.2);
      fg = const Color(0xFFFF5252);
    }

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => _onKeyAction(action),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isPrimary ? const Color(0xFF448AFF) : borderColor,
              ),
            ),
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== FULLSCREEN MIRROR SCAFFOLD ====================
  Widget _buildFullscreenMirrorScaffold(bool isDark, Color surfaceColor, Color borderColor, Color textColor, Color mutedColor) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Fullscreen Mirrored Touch Display (Works like a Trackpad, no mouse jump)
          _buildInteractiveMirrorView(),

          // Icon-only Exit Fullscreen button on the top right corner
          Positioned(
            top: 14,
            right: 14,
            child: SafeArea(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _toggleFullScreenMirror,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF00E676), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.6),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.fullscreen_exit_rounded,
                        size: 26,
                        color: Color(0xFF00E676),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
