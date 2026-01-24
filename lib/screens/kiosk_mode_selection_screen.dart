import 'package:flutter/material.dart';
import '../config/app_config.dart';
import '../models/kiosk_mode.dart';
import '../widgets/kiosk_mode_card.dart';
import 'kiosk_webview_screen.dart';

/// Screen that displays three kiosk mode options for the user to choose from
class KioskModeSelectionScreen extends StatelessWidget {
  const KioskModeSelectionScreen({super.key});

  /// Brand colors used throughout the app
  static const brandColor = Color(0xFFC2410C);
  static const brandDark = Color(0xFF7C2D12);
  static const brandLight = Color(0xFFFFF2E9);

  /// Navigate to the webview with the selected kiosk mode
  void _openKioskMode(BuildContext context, KioskMode mode) {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) {
          return KioskWebViewScreen(kioskUrl: mode.url, title: mode.title);
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
  }

  /// Get the list of available kiosk modes
  List<KioskMode> _getKioskModes() {
    return [
      KioskMode(
        type: KioskModeType.kiosk,
        title: 'KIOSK',
        subtitle: 'Self-Service Kiosk',
        icon: Icons.storefront_rounded,
        url: AppConfig.kioskUrl,
        color: brandColor,
      ),
      KioskMode(
        type: KioskModeType.largeKiosk,
        title: 'LARGE KIOSK',
        subtitle: 'Large Display Kiosk',
        icon: Icons.tv_rounded,
        url: AppConfig.largeKioskUrl,
        color: brandColor,
      ),
      KioskMode(
        type: KioskModeType.pos,
        title: 'POS',
        subtitle: 'Point of Sale System',
        icon: Icons.point_of_sale_rounded,
        url: AppConfig.posUrl,
        color: brandColor,
      ),
      KioskMode(
        type: KioskModeType.mobileKiosk,
        title: 'MOBILE KIOSK',
        subtitle: 'Mobile Device Kiosk',
        icon: Icons.phone_android_rounded,
        url: AppConfig.mobileKioskUrl,
        color: brandColor,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final kioskModes = _getKioskModes();
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: SafeArea(
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [brandLight, Color(0xFFFFFFFF)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: screenWidth < 400 ? 16 : 24,
            vertical: 12,
          ),
          child: Column(
            children: [
              const Spacer(flex: 1),
              // Title
              Text(
                'Choose Mode',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: screenWidth < 400 ? 20 : 24,
                  fontWeight: FontWeight.w900,
                  color: brandDark,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              // Subtitle
              const Text(
                'Select your preferred mode',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.black54,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              // Kiosk mode cards - centered with max size
              Expanded(
                flex: 5,
                child: Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isNarrow = constraints.maxWidth < 700;
                      // Limit max height and width for better proportions
                      final maxWidth = isNarrow ? 400.0 : 800.0;
                      final maxHeight = isNarrow ? 320.0 : 200.0;

                      // 2x2 Grid layout for mobile
                      if (isNarrow) {
                        return ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: maxWidth,
                            maxHeight: maxHeight,
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    KioskModeCard(
                                      mode: kioskModes[0],
                                      onTap: () => _openKioskMode(
                                        context,
                                        kioskModes[0],
                                      ),
                                      useExpanded: true,
                                    ),
                                    const SizedBox(width: 10),
                                    KioskModeCard(
                                      mode: kioskModes[1],
                                      onTap: () => _openKioskMode(
                                        context,
                                        kioskModes[1],
                                      ),
                                      useExpanded: true,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              Expanded(
                                child: Row(
                                  children: [
                                    KioskModeCard(
                                      mode: kioskModes[2],
                                      onTap: () => _openKioskMode(
                                        context,
                                        kioskModes[2],
                                      ),
                                      useExpanded: true,
                                    ),
                                    const SizedBox(width: 10),
                                    KioskModeCard(
                                      mode: kioskModes[3],
                                      onTap: () => _openKioskMode(
                                        context,
                                        kioskModes[3],
                                      ),
                                      useExpanded: true,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      // Horizontal layout for wider screens
                      return ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: maxWidth,
                          maxHeight: maxHeight,
                        ),
                        child: Row(
                          children: [
                            for (int i = 0; i < kioskModes.length; i++) ...[
                              KioskModeCard(
                                mode: kioskModes[i],
                                onTap: () =>
                                    _openKioskMode(context, kioskModes[i]),
                                useExpanded: true,
                              ),
                              if (i < kioskModes.length - 1)
                                const SizedBox(width: 12),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const Spacer(flex: 1),
            ],
          ),
        ),
      ),
    );
  }
}
