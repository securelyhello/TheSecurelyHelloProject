import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/widgets/app_text_field.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _usernameController = TextEditingController();
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  
  bool _obscurePassword = true;
  bool? _isUsernameAvailable;
  bool _isCheckingUsername = false;

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
    _confirmController.dispose();
    _usernameController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _checkUsername(String value) async {
    if (value.length < 3) {
      setState(() => _isUsernameAvailable = null);
      return;
    }
    
    setState(() => _isCheckingUsername = true);
    final available = await context.read<ContactsProvider>().isUsernameAvailable(value);
    
    if (mounted && _usernameController.text == value) {
      setState(() {
        _isCheckingUsername = false;
        _isUsernameAvailable = available;
      });
    }
  }

  void _signup() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isUsernameAvailable == false) return;
    
    final auth = context.read<AuthProvider>();
    final success = await auth.signUp(
      email: _emailController.text.trim(),
      password: _passwordController.text,
      username: _usernameController.text.trim(),
      displayName: _nameController.text.trim(),
    );
    
    if (!success || !mounted) return;
    // Offer verification right away when the server can e-mail a code.
    final offer = !auth.emailVerified && await auth.emailAvailable();
    if (mounted) {
      Navigator.of(context)
          .pushReplacementNamed(offer ? '/verify-email' : '/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
          onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Create your account',
                  style: GoogleFonts.manrope(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Join Securely Hello and chat privately.',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    color: const Color(0xFFB8B8CC),
                  ),
                ),
                const SizedBox(height: 32),
                AppTextField(
                  controller: _emailController,
                  label: 'Email',
                  hint: 'Enter your email',
                  prefixIcon: const Icon(LucideIcons.mail),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) => v!.isEmpty || !v.contains('@') ? 'Valid email required' : null,
                ),
                const SizedBox(height: 20),
                AppTextField(
                  controller: _nameController,
                  label: 'Display Name',
                  hint: 'How others will see you',
                  prefixIcon: const Icon(LucideIcons.user),
                  validator: (v) => v!.isEmpty ? 'Display name is required' : null,
                ),
                const SizedBox(height: 20),
                AppTextField(
                  controller: _usernameController,
                  label: 'Username',
                  hint: 'e.g. johndoe',
                  prefixIcon: const Icon(LucideIcons.atSign),
                  onChanged: _checkUsername,
                  suffixIcon: _isCheckingUsername 
                    ? const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _isUsernameAvailable != null 
                        ? Icon(
                            _isUsernameAvailable! ? LucideIcons.check : LucideIcons.x,
                            color: _isUsernameAvailable! ? const Color(0xFF34D399) : const Color(0xFFEF4444),
                          )
                        : null,
                  validator: (v) {
                    if (v!.length < 3) return 'Min 3 characters';
                    if (!RegExp(r'^[a-zA-Z0-9_]{3,30}$').hasMatch(v.trim())) {
                      return 'Letters, numbers and _ only (max 30)';
                    }
                    if (_isUsernameAvailable == false) return 'Username is taken';
                    return null;
                  },
                ),
                const SizedBox(height: 20),
                AppTextField(
                  controller: _passwordController,
                  label: 'Password',
                  hint: 'Create a strong password',
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
                  validator: (v) => v!.length < 8 ? 'At least 8 characters' : null,
                ),
                const SizedBox(height: 8),
                // Simple password strength indicator
                Row(
                  children: List.generate(4, (index) {
                    final length = _passwordController.text.length;
                    final active = length > index * 3;
                    return Expanded(
                      child: Container(
                        height: 4,
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          color: active ? const Color(0xFF00E5CC) : const Color(0xFF2A2A3E),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 20),
                AppTextField(
                  controller: _confirmController,
                  label: 'Confirm Password',
                  hint: 'Repeat your password',
                  prefixIcon: const Icon(LucideIcons.lock),
                  obscureText: _obscurePassword,
                  validator: (v) => v != _passwordController.text ? 'Passwords do not match' : null,
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
                  onPressed: authProvider.isLoading ? null : _signup,
                  child: authProvider.isLoading
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text('Sign up'),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Already have an account?',
                      style: GoogleFonts.inter(color: const Color(0xFFB8B8CC)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
                      child: const Text('Log in'),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
