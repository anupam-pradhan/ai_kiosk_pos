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
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late AnimationController _shimmerController;
  late Animation<double> _letterAnimation1;
  late Animation<double> _letterAnimation2;
  late Animation<double> _letterAnimation3;
  late Animation<double> _letterAnimation4;
  late Animation<double> _letterAnimation5;
  late Animation<double> _letterAnimation6;
  late Animation<double> _letterAnimation7;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _shimmerAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 2500),
      vsync: this,
    );

    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    // Each letter appears with a stagger effect
    _letterAnimation1 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.15, curve: Curves.elasticOut),
      ),
    );

    _letterAnimation2 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.08, 0.23, curve: Curves.elasticOut),
      ),
    );

    _letterAnimation3 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.16, 0.31, curve: Curves.elasticOut),
      ),
    );

    _letterAnimation4 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.24, 0.39, curve: Curves.elasticOut),
      ),
    );

    _letterAnimation5 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.32, 0.47, curve: Curves.elasticOut),
      ),
    );

    _letterAnimation6 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.40, 0.55, curve: Curves.elasticOut),
      ),
    );

    _letterAnimation7 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.48, 0.63, curve: Curves.elasticOut),
      ),
    );

    // Shimmer animation
    _shimmerAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );

    // Scale animation - zoom out
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 70.0),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.05,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 10.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.05,
          end: 20.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 20.0,
      ),
    ]).animate(_controller);

    // Fade out at the end
    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.85, 1.0, curve: Curves.easeIn),
      ),
    );

    _controller.forward();

    // Delay before starting shimmer to avoid flicker
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted && _controller.isCompleted) {
        _shimmerController.forward();
      }
    });

    // Navigate after animations complete
    Future.delayed(const Duration(milliseconds: 3000), () {
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
    _shimmerController.dispose();
    super.dispose();
  }

  Widget _buildLetter(
    String letter,
    Animation<double> animation,
    double fontSize,
  ) {
    return Transform.scale(
      scale: animation.value.clamp(0.0, 10.0),
      child: Transform.translate(
        offset: Offset(0, 30 * (1 - animation.value.clamp(0.0, 1.0))),
        child: Opacity(
          opacity: animation.value.clamp(0.0, 1.0),
          child: ShaderMask(
            shaderCallback: (bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFc2410c), // Dark orange
                  Color(0xFF9a3412), // Darker orange
                  Color(0xFF7c2d12), // Darkest orange
                ],
                stops: [0.0, 0.5, 1.0],
              ).createShader(bounds);
            },
            child: Text(
              letter,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: fontSize > 60 ? -4 : -2,
                height: 1.0,
                fontFamily: 'SF Pro Display',
                shadows: [
                  Shadow(
                    color: const Color(0xFFc2410c).withOpacity(0.5),
                    offset: const Offset(0, 4),
                    blurRadius: 8,
                  ),
                  const Shadow(
                    color: Color(0x30000000),
                    offset: Offset(0, 2),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallDevice = screenWidth < 400;
    final fontSize = isSmallDevice ? 48.0 : 72.0;
    final horizontalPadding = isSmallDevice ? 20.0 : 45.0;
    final verticalPadding = isSmallDevice ? 18.0 : 30.0;
    final borderRadius = isSmallDevice ? 25.0 : 35.0;

    return Scaffold(
      backgroundColor: const Color(0xFFc2410c), // Match native splash #c2410c
      body: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_controller, _shimmerController]),
          builder: (context, child) {
            final fadeValue = _fadeAnimation.value.clamp(0.0, 1.0);
            final scaleValue = _scaleAnimation.value.clamp(0.0, 20.0);

            return Opacity(
              opacity: fadeValue,
              child: Transform.scale(
                scale: scaleValue,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Main container with clean design
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                        vertical: verticalPadding,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(borderRadius),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 40,
                            offset: const Offset(0, 15),
                            spreadRadius: -5,
                          ),
                          BoxShadow(
                            color: const Color(0xFFc2410c).withOpacity(0.2),
                            blurRadius: 60,
                            offset: const Offset(0, 25),
                            spreadRadius: -10,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildLetter('M', _letterAnimation1, fontSize),
                          _buildLetter('E', _letterAnimation2, fontSize),
                          _buildLetter('G', _letterAnimation3, fontSize),
                          _buildLetter('A', _letterAnimation4, fontSize),
                          _buildLetter('P', _letterAnimation5, fontSize),
                          _buildLetter('O', _letterAnimation6, fontSize),
                          _buildLetter('S', _letterAnimation7, fontSize),
                        ],
                      ),
                    ),
                    // Shimmer effect overlay - only show when safe
                    if (_controller.value > 0.7 &&
                        _shimmerController.value > 0 &&
                        _shimmerController.value < 1.0)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(borderRadius),
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment(
                                    -1.0 + (_shimmerController.value * 3),
                                    -1.0,
                                  ),
                                  end: Alignment(
                                    -1.0 + (_shimmerController.value * 3) + 0.5,
                                    1.0,
                                  ),
                                  colors: [
                                    Colors.white.withOpacity(0.0),
                                    Colors.white.withOpacity(0.4),
                                    Colors.white.withOpacity(0.0),
                                  ],
                                  stops: const [0.0, 0.5, 1.0],
                                ),
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
      ),
    );
  }
}
