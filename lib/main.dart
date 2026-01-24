import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'animated_splash.dart';
import 'config/app_config.dart';
import 'screens/kiosk_mode_selection_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    // If .env file doesn't exist, continue with defaults
    if (kDebugMode) {
      print('Warning: .env file not found, using defaults');
    }
  }

  // Print configuration in debug mode
  AppConfig.printConfig();

  runApp(const KioskApp());
}

class KioskApp extends StatelessWidget {
  const KioskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MEGAPOS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC2410C)),
        useMaterial3: true,
      ),
      home: AnimatedSplashScreen(
        duration: const Duration(milliseconds: 2000),
        child: const KioskModeSelectionScreen(),
      ),
    );
  }
}
