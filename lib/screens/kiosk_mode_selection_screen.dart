import 'dart:ui';
import 'package:flutter/material.dart';
import '../config/app_config.dart';
import '../models/kiosk_mode.dart';
import '../widgets/kiosk_mode_card.dart';
import 'kiosk_webview_screen.dart';

/// Screen that displays three kiosk mode options for the user to choose from
class KioskModeSelectionScreen extends StatefulWidget {
  const KioskModeSelectionScreen({super.key});

  @override
  State<KioskModeSelectionScreen> createState() =>
      _KioskModeSelectionScreenState();
}

class _KioskModeSelectionScreenState extends State<KioskModeSelectionScreen> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // Simulate loading delay for skeleton effect
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    });
  }

  /// Brand colors used throughout the app
  static const brandColor = Color(0xFFC2410C);
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
            vertical: 8,
          ),
          child: _isLoading
              ? _buildSkeletonView(screenWidth)
              : Column(
                  children: [
                    const Spacer(flex: 2),
                    // Title with elegant animation
                    Center(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOut,
                        builder: (context, value, child) {
                          return Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(0, 20 * (1 - value)),
                              child: child,
                            ),
                          );
                        },
                        child: Text(
                          'Choose Mode',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: screenWidth < 400 ? 24 : 28,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                            color: const Color(0xFF1D1D1F),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Subtitle
                    const Center(
                      child: Text(
                        'Select your preferred mode',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF6E6E73),
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
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
                                    const SizedBox(height: 15),
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
                                  for (
                                    int i = 0;
                                    i < kioskModes.length;
                                    i++
                                  ) ...[
                                    KioskModeCard(
                                      mode: kioskModes[i],
                                      onTap: () => _openKioskMode(
                                        context,
                                        kioskModes[i],
                                      ),
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
                    const Spacer(flex: 2),
                  ],
                ),
        ),
      ),
    );
  }

  /// Build skeleton loading view with elegant shimmer effect
  Widget _buildSkeletonView(double screenWidth) {
    return Column(
      children: [
        const Spacer(flex: 2),
        // Skeleton title
        _buildSkeletonBox(
          width: 160,
          height: screenWidth < 400 ? 24 : 28,
          borderRadius: 8,
        ),
        const SizedBox(height: 6),
        // Skeleton subtitle
        _buildSkeletonBox(width: 180, height: 12, borderRadius: 6),
        const SizedBox(height: 10),
        // Skeleton cards
        Expanded(
          flex: 5,
          child: Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 700;
                final maxWidth = isNarrow ? 400.0 : 800.0;
                final maxHeight = isNarrow ? 320.0 : 200.0;

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
                              Expanded(child: _buildSkeletonCard()),
                              const SizedBox(width: 10),
                              Expanded(child: _buildSkeletonCard()),
                            ],
                          ),
                        ),
                        const SizedBox(height: 15),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(child: _buildSkeletonCard()),
                              const SizedBox(width: 10),
                              Expanded(child: _buildSkeletonCard()),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: maxWidth,
                    maxHeight: maxHeight,
                  ),
                  child: Row(
                    children: [
                      for (int i = 0; i < 4; i++) ...[
                        Expanded(child: _buildSkeletonCard()),
                        if (i < 3) const SizedBox(width: 12),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const Spacer(flex: 2),
      ],
    );
  }

  /// Build a skeleton card with glassmorphism and shimmer
  Widget _buildSkeletonCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withOpacity(0.9),
                Colors.white.withOpacity(0.7),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withOpacity(0.8),
              width: 1.5,
            ),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildSkeletonBox(width: 72, height: 72, isCircle: true),
              const SizedBox(height: 14),
              _buildSkeletonBox(width: 90, height: 16, borderRadius: 6),
              const SizedBox(height: 6),
              _buildSkeletonBox(width: 110, height: 12, borderRadius: 5),
            ],
          ),
        ),
      ),
    );
  }

  /// Build a skeleton box with smooth shimmer animation
  Widget _buildSkeletonBox({
    required double width,
    required double height,
    bool isCircle = false,
    double borderRadius = 8,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        final shimmerValue = (value * 2).clamp(0.0, 1.0);
        final opacity = shimmerValue < 0.5
            ? 0.15 + (shimmerValue * 0.15)
            : 0.3 - ((shimmerValue - 0.5) * 0.15);

        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                brandColor.withOpacity(opacity),
                brandColor.withOpacity(opacity + 0.08),
                brandColor.withOpacity(opacity),
              ],
              stops: const [0.0, 0.5, 1.0],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              transform: GradientRotation(value * 6.28), // Full rotation
            ),
            borderRadius: isCircle ? null : BorderRadius.circular(borderRadius),
            shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
            boxShadow: [
              BoxShadow(
                color: brandColor.withOpacity(0.05),
                blurRadius: 8,
                spreadRadius: -2,
              ),
            ],
          ),
        );
      },
      onEnd: () {
        if (mounted) setState(() {});
      },
    );
  }
}
