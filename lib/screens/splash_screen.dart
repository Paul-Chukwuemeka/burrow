import 'package:flutter/material.dart';

/// Splash screen shown during app initialization. Fades in the app name on
/// the brand-green background, then hands off to the appropriate home screen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onReady});

  /// Called once initialization completes. Returns the built home widget.
  final Future<Widget> Function(BuildContext context) onReady;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeIn = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigateToHome();
    });
  }

  Future<void> _navigateToHome() async {
    final home = await widget.onReady(context);

    // Keep the splash visible for at least a short beat so it feels intentional.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, a, b) => home,
        transitionsBuilder: (_, animation, c, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ColoredBox(
        color: Color(0xFF2E6E4E),
        child: Center(
          child: FadeTransition(
            opacity: _fadeIn,
            child: Text(
              'burrow',
              style: TextStyle(
                fontFamily: 'Fraunces',
                fontSize: 42,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
