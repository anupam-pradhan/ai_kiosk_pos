import 'package:flutter/material.dart';
// ignore: unused_import
import 'dart:ui' as ui;

class AnimatedSplashScreen extends StatefulWidget {
  final Widget child;
  final Duration duration;

  const AnimatedSplashScreen({
    super.key,
    required this.child,
    this.duration = const Duration(seconds: 2),
  });

  @override
  State<AnimatedSplashScreen> createState() => _AnimatedSplashScreenState();
}

class _AnimatedSplashScreenState extends State<AnimatedSplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _drawAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _textAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2200),
      vsync: this,
    );

    // Drawing animation (0.0 to 0.35) - letter draws in
    _drawAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.35, curve: Curves.easeInOut),
      ),
    );

    // Text fade in animation (0.35 to 0.5)
    _textAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.5, curve: Curves.easeIn),
      ),
    );

    // Scale animation (0.5 to 1.0) - Twitter-style zoom
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 50.0, // Wait during drawing and text
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.05,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 15.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.05,
          end: 20.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 35.0,
      ),
    ]).animate(_controller);

    // Fade out at the end
    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.8, 1.0, curve: Curves.easeIn),
      ),
    );

    _controller.forward().then((_) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                widget.child,
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(opacity: animation, child: child);
                },
            transitionDuration: const Duration(milliseconds: 300),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFc2410c),
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Opacity(
              opacity: _fadeAnimation.value,
              child: Transform.scale(
                scale: _scaleAnimation.value,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(40),
                      ),
                      child: CustomPaint(
                        painter: MLogoPainter(_drawAnimation.value),
                      ),
                    ),
                    const SizedBox(height: 30),
                    Opacity(
                      opacity: _textAnimation.value,
                      child: Column(
                        children: [
                          const Text(
                            'MegaPos Kiosk',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '🍔  🍕  🥤',
                            style: TextStyle(
                              fontSize: 20,
                              color: Colors.white.withOpacity(0.9),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// Custom painter to draw the M logo with animation
class MLogoPainter extends CustomPainter {
  final double progress;

  MLogoPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    // Define M letter dimensions
    final padding = size.width * 0.15;
    final startX = padding;
    final startY = size.height * 0.75;
    final midX = size.width * 0.5;
    final midY = size.height * 0.45;
    final endX = size.width - padding;
    final endY = size.height * 0.75;
    final topY = size.height * 0.25;

    // Create the M path
    final path = Path();
    path.moveTo(startX, startY);
    path.lineTo(startX, topY);
    path.lineTo(midX, midY);
    path.lineTo(endX, topY);
    path.lineTo(endX, endY);

    if (progress < 1.0) {
      // Drawing phase - stroke only
      final strokePaint = Paint()
        ..color = const Color(0xFFc2410c)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final pathMetrics = path.computeMetrics();
      final animatedPath = Path();

      for (final metric in pathMetrics) {
        final extractPath = metric.extractPath(0.0, metric.length * progress);
        animatedPath.addPath(extractPath, Offset.zero);
      }

      canvas.drawPath(animatedPath, strokePaint);
    } else {
      // Completed phase - clean filled M
      final fillPaint = Paint()
        ..color = const Color(0xFFc2410c)
        ..style = PaintingStyle.fill;

      // Create closed path for clean fill
      final fillPath = Path();
      fillPath.moveTo(startX, startY);
      fillPath.lineTo(startX, topY);
      fillPath.lineTo(midX, midY);
      fillPath.lineTo(endX, topY);
      fillPath.lineTo(endX, endY);

      // Close bottom to create filled shape
      fillPath.lineTo(endX - 8, endY);
      fillPath.lineTo(endX - 8, topY + 15);
      fillPath.lineTo(midX, midY + 10);
      fillPath.lineTo(startX + 8, topY + 15);
      fillPath.lineTo(startX + 8, endY);
      fillPath.close();

      canvas.drawPath(fillPath, fillPaint);
    }
  }

  @override
  bool shouldRepaint(MLogoPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
