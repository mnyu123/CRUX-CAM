import 'package:flutter/material.dart';

import 'routes.dart';

class CruxCamApp extends StatelessWidget {
  const CruxCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB5F56A),
      brightness: Brightness.dark,
      surface: const Color(0xFF151A20),
    );
    return MaterialApp(
      title: 'CRUX-CAM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0C1015),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0C1015),
          centerTitle: false,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      initialRoute: AppRoutes.media,
      routes: AppRoutes.routes,
      navigatorObservers: [mediaRouteObserver],
    );
  }
}
