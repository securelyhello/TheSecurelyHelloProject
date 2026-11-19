import 'dart:async';
import 'package:flutter/material.dart';

import 'package:securelyhello/shared/widgets/brand_logo.dart';
import 'package:provider/provider.dart';
import 'package:securelyhello/shared/theme/app_fonts.dart';
import 'package:securelyhello/features/auth/screens/welcome_screen.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  bool _animationCompleted = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack),
      ),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 1.0, curve: Curves.easeIn),
      ),
    );

    _controller.forward();

    // After animation, set flag and check auth state
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      _animationCompleted = true;
      _checkAndNavigate();
    });
  }

  void _checkAndNavigate() {
    if (!_animationCompleted || !mounted) return;
    
    final authProvider = context.read<AuthProvider>();
    
    // If still initializing, listen for changes
    if (authProvider.isLoading || authProvider.status == AuthStatus.initial) {
      authProvider.addListener(_authListener);
    } else {
      _navigate(authProvider.status);
    }
  }

  void _authListener() {
    final authProvider = context.read<AuthProvider>();
    if (!authProvider.isLoading && authProvider.status != AuthStatus.initial) {
      authProvider.removeListener(_authListener);
      _navigate(authProvider.status);
    }
  }

  Future<void> _navigate(AuthStatus status) async {
    if (!mounted) return;
    if (status == AuthStatus.authenticated) {
      Navigator.of(context)
          .pushReplacementNamed(context.read<AuthProvider>().homeRoute);
      return;
    }
    final seen = await WelcomeScreen.seen();
    if (mounted) Navigator.of(context).pushReplacementNamed(seen ? '/login' : '/welcome');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
              scale: _scaleAnimation,
              child: const BrandLogo(size: 120),
            ),
            const SizedBox(height: 32),
            FadeTransition(
              opacity: _fadeAnimation,
              child: Text(
                'Securely Hello',
                style: AppFonts.heading(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: context.palette.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
