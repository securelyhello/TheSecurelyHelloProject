import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/widgets/app_text_field.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
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
    super.dispose();
  }

  void _login() async {
    if (!_formKey.currentState!.validate()) return;
    
    final success = await context.read<AuthProvider>().signIn(
      email: _emailController.text.trim(),
      password: _passwordController.text,
    );
    
    if (success && mounted) {
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 48),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF00E5CC).withValues(alpha: 0.1),
                    ),
                    child: const Icon(
                      LucideIcons.shieldCheck,
                      size: 48,
                      color: Color(0xFF00E5CC),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Welcome back',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.manrope(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 48),
                AppTextField(
                  controller: _emailController,
                  label: 'Email',
                  hint: 'Enter your email',
                  prefixIcon: const Icon(LucideIcons.mail),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) => v!.isEmpty ? 'Email is required' : null,
                ),
                const SizedBox(height: 20),
                AppTextField(
                  controller: _passwordController,
                  label: 'Password',
                  hint: 'Enter your password',
                  prefixIcon: const Icon(LucideIcons.lock),
                  obscureText: _obscurePassword,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? LucideIcons.eye : LucideIcons.eyeOff,
                      color: const Color(0xFF6B6B80),
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                  validator: (v) => v!.isEmpty ? 'Password is required' : null,
                ),
                const SizedBox(height: 32),
                if (authProvider.errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            authProvider.errorMessage!,
                            style: GoogleFonts.inter(color: const Color(0xFFEF4444), fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ElevatedButton(
                  onPressed: authProvider.isLoading ? null : _login,
                  child: authProvider.isLoading
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text('Log in'),
                ),
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Don\'t have an account?',
                      style: GoogleFonts.inter(color: const Color(0xFFB8B8CC)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pushReplacementNamed(context, '/signup'),
                      child: const Text('Sign up'),
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
