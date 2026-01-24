import 'package:flutter/material.dart';

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
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _sweepAnimation;
  late final List<Animation<double>> _letterAnimations;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 2300),
      vsync: this,
    );

    _letterAnimations = List.generate(7, (index) {
      final start = 0.08 + (index * 0.06);
      final end = start + 0.26;
      return CurvedAnimation(
        parent: _controller,
        curve: Interval(start, end, curve: Curves.easeOutCubic),
      );
    });

    _sweepAnimation = Tween<double>(begin: -1.2, end: 1.2).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.45, 0.9)),
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.92,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.05,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_controller);

    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.85, 1.0, curve: Curves.easeIn),
      ),
    );

    _controller.forward();

    Future.delayed(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => widget.child,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 320),
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildLetter(
    String letter,
    Animation<double> animation,
    double size,
    double letterSpacing,
  ) {
    final value = animation.value.clamp(0.0, 1.0);
    return Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, 24 * (1 - value)),
        child: ShaderMask(
          shaderCallback: (bounds) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFFFFFF), Color(0xFFFFE2D4), Color(0xFFFFC3A8)],
            ).createShader(bounds);
          },
          child: Text(
            letter,
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w900,
              letterSpacing: letterSpacing,
              color: Colors.white,
              shadows: [
                const Shadow(
                  color: Color(0x66000000),
                  offset: Offset(0, 6),
                  blurRadius: 16,
                ),
                Shadow(
                  color: const Color(0xFF9A3412).withOpacity(0.6),
                  offset: const Offset(0, 0),
                  blurRadius: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSweepText(String text, double size, double letterSpacing) {
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (bounds) {
        final start = _sweepAnimation.value;
        return LinearGradient(
          begin: Alignment(start, -1),
          end: Alignment(start + 0.7, 1),
          colors: [
            Colors.transparent,
            Colors.white.withOpacity(0.8),
            Colors.transparent,
          ],
          stops: const [0.2, 0.5, 0.8],
        ).createShader(bounds);
      },
      child: Text(
        text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w900,
          letterSpacing: letterSpacing,
          color: const Color(0xFFFFEDE3),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFC2410C),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final shortest = size.shortestSide;
          final fontSize = (shortest * 0.18).clamp(42.0, 84.0);
          final letterSpacing = (shortest * 0.0035).clamp(0.6, 1.6);
          final underlineWidth = (shortest * 0.5).clamp(160.0, 260.0);

          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Opacity(
                opacity: _fadeAnimation.value,
                child: Transform.scale(
                  scale: _scaleAnimation.value,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              colors: [
                                const Color(0xFFFF6A2E).withOpacity(0.25),
                                const Color(0xFFC2410C),
                              ],
                              radius: 1.0,
                              center: const Alignment(0.0, -0.2),
                            ),
                          ),
                        ),
                      ),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildLetter(
                                      'M',
                                      _letterAnimations[0],
                                      fontSize,
                                      letterSpacing,
                                    ),
                                    _buildLetter(
                                      'E',
                                      _letterAnimations[1],
                                      fontSize,
                                      letterSpacing,
                                    ),
                                    _buildLetter(
                                      'G',
                                      _letterAnimations[2],
                                      fontSize,
                                      letterSpacing,
                                    ),
                                    _buildLetter(
                                      'A',
                                      _letterAnimations[3],
                                      fontSize,
                                      letterSpacing,
                                    ),
                                    _buildLetter(
                                      'P',
                                      _letterAnimations[4],
                                      fontSize,
                                      letterSpacing,
                                    ),
                                    _buildLetter(
                                      'O',
                                      _letterAnimations[5],
                                      fontSize,
                                      letterSpacing,
                                    ),
                                    _buildLetter(
                                      'S',
                                      _letterAnimations[6],
                                      fontSize,
                                      letterSpacing,
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: shortest * 0.02),
                              Container(
                                height: 2,
                                width: underlineWidth,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFFFF),
                                  borderRadius: BorderRadius.circular(2),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFFFFFFFF,
                                      ).withOpacity(0.35),
                                      blurRadius: 18,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IgnorePointer(
                        child: Opacity(
                          opacity: 0.7,
                          child: _buildSweepText(
                            'MEGAPOS',
                            fontSize,
                            letterSpacing,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
