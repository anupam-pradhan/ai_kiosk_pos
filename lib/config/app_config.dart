import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Central configuration class for managing app settings and environment variables
class AppConfig {
  // Private constructor to prevent instantiation
  AppConfig._();

  /// Get the current app mode (test or live)
  static String get appMode =>
      dotenv.env['APP_MODE'] ??
      const String.fromEnvironment('APP_MODE', defaultValue: 'test');

  /// Check if app is running in live mode
  static bool get isLive => appMode.toLowerCase() == 'live';

  /// Check if tap to pay is simulated (defaults to true in test mode, false in live)
  static bool get isTapToPaySimulated {
    final raw =
        dotenv.env['TAP_TO_PAY_SIMULATED'] ??
        const String.fromEnvironment('TAP_TO_PAY_SIMULATED', defaultValue: '');
    if (raw.isEmpty) return !isLive;
    return raw.toLowerCase() == 'true';
  }

  // ========== TEST URL (Single URL for all modes) ==========

  /// Single test URL for all modes (local development)
  static String get testUrl =>
      dotenv.env['TEST_URL'] ??
      const String.fromEnvironment(
        'TEST_URL',
        defaultValue: 'http://192.168.1.161:3000',
      );

  // ========== KIOSK Mode URLs ==========

  /// Kiosk URL for live environment
  static String get kioskUrlLive =>
      dotenv.env['KIOSK_URL_LIVE'] ??
      const String.fromEnvironment(
        'KIOSK_URL_LIVE',
        defaultValue: 'https://aikiosk.example.com/kiosk',
      );

  /// Get active Kiosk URL based on current mode
  static String get kioskUrl => isLive ? kioskUrlLive : testUrl;

  // ========== LARGE KIOSK Mode URLs ==========

  /// Large Kiosk URL for live environment
  static String get largeKioskUrlLive =>
      dotenv.env['LARGE_KIOSK_URL_LIVE'] ??
      const String.fromEnvironment(
        'LARGE_KIOSK_URL_LIVE',
        defaultValue: 'https://aikiosk.example.com/largekiosk',
      );

  /// Get active Large Kiosk URL based on current mode
  static String get largeKioskUrl => isLive ? largeKioskUrlLive : testUrl;

  // ========== POS Mode URLs ==========

  /// POS URL for live environment
  static String get posUrlLive =>
      dotenv.env['POS_URL_LIVE'] ??
      const String.fromEnvironment(
        'POS_URL_LIVE',
        defaultValue: 'https://aikiosk.example.com/pos',
      );

  /// Get active POS URL based on current mode
  static String get posUrl => isLive ? posUrlLive : testUrl;

  // ========== MOBILE KIOSK Mode URLs ==========

  /// Mobile Kiosk URL for live environment
  static String get mobileKioskUrlLive =>
      dotenv.env['MOBILE_KIOSK_URL_LIVE'] ??
      const String.fromEnvironment(
        'MOBILE_KIOSK_URL_LIVE',
        defaultValue: 'https://aikiosk.example.com/mobilekiosk',
      );

  /// Get active Mobile Kiosk URL based on current mode
  static String get mobileKioskUrl => isLive ? mobileKioskUrlLive : testUrl;

  /// Print current configuration (for debugging)
  static void printConfig() {
    if (kDebugMode) {
      print('========== App Configuration ==========');
      print('App Mode: $appMode');
      print('Is Live: $isLive');
      print('Tap to Pay Simulated: $isTapToPaySimulated');
      print('');
      print('--- URLs ---');
      if (!isLive) {
        print('Test URL (all modes): $testUrl');
      } else {
        print('Kiosk: $kioskUrl');
        print('Large Kiosk: $largeKioskUrl');
        print('POS: $posUrl');
        print('Mobile Kiosk: $mobileKioskUrl');
      }
      print('=======================================');
    }
  }
}
