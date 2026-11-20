import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/features/auth/screens/auth_paper.dart';
import 'package:securelyhello/features/auth/widgets/otp_field.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/widgets/app_text_field.dart';
import 'package:securelyhello/shared/widgets/brand_logo.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    // Don't carry an error over from the screen we came from.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _login() async {
    if (!_formKey.currentState!.validate()) return;
    
    final success = await context.read<AuthProvider>().signIn(
      email: _emailController.text.trim(),
      password: _passwordController.text,
      otp: _otpController.text,
    );
    
    if (success && mounted) {
      Navigator.of(context)
          .pushReplacementNamed(context.read<AuthProvider>().homeRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    
    return Scaffold(
      backgroundColor: context.palette.background,
      body: SafeArea(
        bottom: false,
        child: AuthPaperLayout(
          header: Column(
            children: [
              const SizedBox(height: 24),
              const BrandLogo(size: 88),
              const SizedBox(height: 20),
              Text(
                L10n.of(context).loginTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ],
          ),
          sheet: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppTextField(
                  controller: _emailController,
                  label: L10n.of(context).email,
                  hint: L10n.of(context).emailHint,
                  prefixIcon: const Icon(LucideIcons.mail),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) => v!.isEmpty ? L10n.of(context).emailRequired : null,
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _passwordController,
                  label: L10n.of(context).password,
                  hint: L10n.of(context).passwordHint,
                  prefixIcon: const Icon(LucideIcons.lock),
                  obscureText: _obscurePassword,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? LucideIcons.eye : LucideIcons.eyeOff,
                      color: context.palette.textMuted,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                  validator: (v) => v!.isEmpty ? L10n.of(context).passwordRequired : null,
                ),
                if (authProvider.otpRequired)
                  OtpField(controller: _otpController, onSubmitted: (_) => _login()),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey('forgot-password'),
                    onPressed: () => Navigator.of(context).pushNamed(
                        '/forgot-password',
                        arguments: _emailController.text.trim()),
                    child: Text(L10n.of(context).forgotPassword),
                  ),
                ),
                const SizedBox(height: 16),
                if (authProvider.errorMessage != null) AuthErrorBanner(authProvider.errorMessage!),
                ElevatedButton(
                  onPressed: authProvider.isLoading ? null : _login,
                  child: authProvider.isLoading
                      ? SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(context.palette.onBrand),
                          ),
                        )
                      : Text(L10n.of(context).logIn),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      L10n.of(context).noAccount,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.palette.textSecondary),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pushReplacementNamed(context, '/signup'),
                      child: Text(L10n.of(context).signUp),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
