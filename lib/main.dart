import 'package:flutter/material.dart';

import 'screens/workbench_screen.dart';
import 'theme/hcom_theme.dart';

void main() => runApp(const HcomApp());

class HcomApp extends StatefulWidget {
  const HcomApp({super.key});

  @override
  State<HcomApp> createState() => _HcomAppState();
}

class _HcomAppState extends State<HcomApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HCOM 调试助手',
        debugShowCheckedModeBanner: false,
        theme: HcomTheme.light(),
        darkTheme: HcomTheme.dark(),
        themeMode: _themeMode,
        themeAnimationDuration: const Duration(milliseconds: 200),
        themeAnimationCurve: Easing.standard,
        home: WorkbenchScreen(
          isDark: _themeMode == ThemeMode.dark,
          onThemeChanged: () => setState(() {
            _themeMode =
                _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
          }),
        ),
      );
}
