import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

class DPadWidget extends StatelessWidget {
  final Function(String command) onCommand;
  final bool isEnabled;

  const DPadWidget({
    super.key,
    required this.onCommand,
    this.isEnabled = true,
  });

  void _trigger(String command) {
    if (!isEnabled) return;
    HapticFeedback.lightImpact();
    onCommand(command);
  }

  @override
  Widget build(BuildContext context) {
    const double padSize = 220.0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final padColor = isDark
        ? AppTheme.darkSurfaceLight.withValues(alpha: 0.85)
        : AppTheme.lightSurfaceLight;
    final padBorder = isDark ? AppTheme.darkSurfaceBorder : AppTheme.lightSurfaceBorder;
    final textColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textMuted = isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted;
    final centerGradient = isDark
        ? const RadialGradient(colors: [Color(0xFF262C3E), Color(0xFF171A24)])
        : const RadialGradient(colors: [Color(0xFFFFFFFF), Color(0xFFDEE5F0)]);

    return Center(
      child: Container(
        width: padSize,
        height: padSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: padColor,
          border: Border.all(color: padBorder, width: 2),
          boxShadow: [
            BoxShadow(
              color: isDark ? Colors.black.withValues(alpha: 0.4) : Colors.black.withValues(alpha: 0.08),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // UP Button
            Positioned(
              top: 8,
              child: _buildPadButton(
                icon: Icons.keyboard_arrow_up_rounded,
                tooltip: 'Up',
                color: isEnabled ? textColor : textMuted,
                onPressed: () => _trigger('navigate_up'),
              ),
            ),

            // DOWN Button
            Positioned(
              bottom: 8,
              child: _buildPadButton(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: 'Down',
                color: isEnabled ? textColor : textMuted,
                onPressed: () => _trigger('navigate_down'),
              ),
            ),

            // LEFT Button
            Positioned(
              left: 8,
              child: _buildPadButton(
                icon: Icons.keyboard_arrow_left_rounded,
                tooltip: 'Left',
                color: isEnabled ? textColor : textMuted,
                onPressed: () => _trigger('navigate_left'),
              ),
            ),

            // RIGHT Button
            Positioned(
              right: 8,
              child: _buildPadButton(
                icon: Icons.keyboard_arrow_right_rounded,
                tooltip: 'Right',
                color: isEnabled ? textColor : textMuted,
                onPressed: () => _trigger('navigate_right'),
              ),
            ),

            // CENTER SELECT Button
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isEnabled ? () => _trigger('select') : null,
                borderRadius: BorderRadius.circular(40),
                splashColor: AppTheme.primary.withValues(alpha: 0.3),
                highlightColor: AppTheme.primary.withValues(alpha: 0.15),
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: centerGradient,
                    border: Border.all(color: padBorder, width: 1.5),
                  ),
                  child: Center(
                    child: Text(
                      'OK',
                      style: TextStyle(
                        color: isEnabled ? textColor : textMuted,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPadButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: IconButton(
        icon: Icon(icon, size: 36),
        color: color,
        tooltip: tooltip,
        splashRadius: 28,
        onPressed: isEnabled ? onPressed : null,
      ),
    );
  }
}
