import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/kiosk_mode.dart';

/// A card widget with authentic Apple-inspired glassmorphism effect
class KioskModeCard extends StatefulWidget {
  final KioskMode mode;
  final VoidCallback onTap;
  final bool useExpanded;

  const KioskModeCard({
    super.key,
    required this.mode,
    required this.onTap,
    this.useExpanded = true,
  });

  @override
  State<KioskModeCard> createState() => _KioskModeCardState();
}

class _KioskModeCardState extends State<KioskModeCard>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  late AnimationController _shineController;
  late Animation<double> _shineAnimation;

  @override
  void initState() {
    super.initState();
    _shineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
    _shineAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shineController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _shineController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cardContent = GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        Future.delayed(const Duration(milliseconds: 100), widget.onTap);
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              // Deep 3D shadow - bottom layer
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 50,
                offset: const Offset(0, 25),
                spreadRadius: -12,
              ),
              // Mid-layer shadow with brand color
              BoxShadow(
                color: widget.mode.color.withOpacity(0.15),
                blurRadius: 30,
                offset: const Offset(0, 15),
                spreadRadius: -6,
              ),
              // Soft ambient shadow
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
                spreadRadius: -4,
              ),
              // Close contact shadow
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 4),
                spreadRadius: -2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withOpacity(0.9),
                      Colors.white.withOpacity(0.7),
                      Colors.white.withOpacity(0.8),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    stops: const [0.0, 0.5, 1.0],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.8),
                    width: 1.5,
                  ),
                ),
                child: Stack(
                  children: [
                    // Top light reflection
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 60,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white.withOpacity(0.6),
                              Colors.white.withOpacity(0.0),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                        ),
                      ),
                    ),
                    // Inner shadow for depth
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 12,
                              offset: const Offset(0, -2),
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Bottom beveled edge
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 40,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.black.withOpacity(0.0),
                              Colors.black.withOpacity(0.02),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(24),
                          ),
                        ),
                      ),
                    ),
                    // Content
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 3D Icon with multiple layers
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    widget.mode.color.withOpacity(0.15),
                                    widget.mode.color.withOpacity(0.08),
                                    widget.mode.color.withOpacity(0.05),
                                  ],
                                  stops: const [0.0, 0.6, 1.0],
                                ),
                                border: Border.all(
                                  color: widget.mode.color.withOpacity(0.1),
                                  width: 1,
                                ),
                                boxShadow: [
                                  // Bottom shadow (colored)
                                  BoxShadow(
                                    color: widget.mode.color.withOpacity(0.3),
                                    blurRadius: 24,
                                    spreadRadius: -3,
                                    offset: const Offset(0, 6),
                                  ),
                                  // Top highlight
                                  BoxShadow(
                                    color: Colors.white.withOpacity(0.6),
                                    blurRadius: 10,
                                    spreadRadius: -2,
                                    offset: const Offset(0, -3),
                                  ),
                                  // Ambient glow
                                  BoxShadow(
                                    color: widget.mode.color.withOpacity(0.15),
                                    blurRadius: 16,
                                    spreadRadius: 0,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Icon(
                                widget.mode.icon,
                                color: widget.mode.color,
                                size: 32,
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Title
                            Text(
                              widget.mode.title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.3,
                                color: Color(0xFF1D1D1F),
                                height: 1.2,
                                shadows: [
                                  Shadow(
                                    color: Colors.white,
                                    offset: Offset(0, 1),
                                    blurRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            // Subtitle
                            Text(
                              widget.mode.subtitle,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF6E6E73),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                letterSpacing: -0.1,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Animated shining effect - elegant diagonal sweep
                    AnimatedBuilder(
                      animation: _shineAnimation,
                      builder: (context, child) {
                        return Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: Stack(
                              children: [
                                // Diagonal shine sweep from top-left
                                Positioned(
                                  top: -200,
                                  left: _shineAnimation.value * 500 - 250,
                                  child: Transform.rotate(
                                    angle: 0.5, // ~30 degrees
                                    child: Container(
                                      width: 150,
                                      height: 500,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            Colors.transparent,
                                            Colors.white.withOpacity(0.15),
                                            Colors.white.withOpacity(0.35),
                                            Colors.white.withOpacity(0.15),
                                            Colors.transparent,
                                          ],
                                          stops: const [
                                            0.0,
                                            0.3,
                                            0.5,
                                            0.7,
                                            1.0,
                                          ],
                                          begin: Alignment.centerLeft,
                                          end: Alignment.centerRight,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    // Pressed overlay
                    if (_isPressed)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            gradient: LinearGradient(
                              colors: [
                                widget.mode.color.withOpacity(0.05),
                                Colors.transparent,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return widget.useExpanded ? Expanded(child: cardContent) : cardContent;
  }
}
