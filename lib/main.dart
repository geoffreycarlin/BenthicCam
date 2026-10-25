import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // video player for the live view
  runApp(const GoProGpsApp());
}

class GoProGpsApp extends StatelessWidget {
  const GoProGpsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GoPro GPS Cam',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            colorSchemeSeed: const Color(0xFF0B6FB8), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF0B6FB8),
            brightness: Brightness.dark,
            useMaterial3: true),
        home: const HomePage(),
      );
}
