import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'screens/host_screen.dart';
import 'screens/remote_screen.dart';
import 'theme/app_theme.dart';

final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.dark);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScrShareApp());
}

class ScrShareApp extends StatelessWidget {
  const ScrShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'ScrShare - YouTube TV Remote',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: currentMode,
          home: const MainContainerScreen(),
        );
      },
    );
  }
}

class MainContainerScreen extends StatefulWidget {
  const MainContainerScreen({super.key});

  @override
  State<MainContainerScreen> createState() => _MainContainerScreenState();
}

class _MainContainerScreenState extends State<MainContainerScreen> {
  late bool _isHostMode;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      _isHostMode = true;
    } else {
      _isHostMode = false;
    }
  }

  void _toggleMode() {
    setState(() {
      _isHostMode = !_isHostMode;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isHostMode) {
      return HostScreen(
        onSwitchToRemote: _toggleMode,
      );
    } else {
      return RemoteScreen(
        onSwitchToHost: (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux))
            ? _toggleMode
            : null,
      );
    }
  }
}
