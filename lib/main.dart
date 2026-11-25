import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'state/scanner_controller.dart';
import 'ui/screens/editor_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SaomiaoApp());
}

class SaomiaoApp extends StatefulWidget {
  const SaomiaoApp({super.key, this.controller});

  final ScannerController? controller;

  @override
  State<SaomiaoApp> createState() => _SaomiaoAppState();
}

class _SaomiaoAppState extends State<SaomiaoApp> {
  late final ScannerController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ScannerController();
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  ThemeMode _resolveThemeMode(String raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return MaterialApp(
          title: '扫描件工坊',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: _resolveThemeMode(_controller.preferences.themeMode),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: EditorScreen(controller: _controller),
        );
      },
    );
  }
}
