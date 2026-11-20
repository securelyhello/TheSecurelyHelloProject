import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/features/settings/screens/legal_screen.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/auth/screens/auth_paper.dart';
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
    
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: context.palette.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(LucideIcons.arrowLeft, color: context.palette.textPrimary),
          onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: AuthPaperLayout(
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(L10n.of(context).signupTitle, style: t.headlineMedium),
              const SizedBox(height: 8),
              Text(
                L10n.of(context).signupSubtitle,
                style: t.bodyLarge?.copyWith(color: context.palette.textSecondary),
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
                  validator: (v) => v!.isEmpty || !v.contains('@') ? L10n.of(context).emailInvalid : null,
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _nameController,
                  label: L10n.of(context).displayName,
                  hint: L10n.of(context).displayNameHint,
                  prefixIcon: const Icon(LucideIcons.user),
                  validator: (v) => v!.isEmpty ? L10n.of(context).displayNameRequired : null,
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _usernameController,
                  label: L10n.of(context).username,
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
                            color: _isUsernameAvailable! ? context.palette.success : context.palette.danger,
                          )
                        : null,
                  validator: (v) {
                    if (v!.length < 3) return L10n.of(context).usernameTooShort;
                    if (!RegExp(r'^[a-zA-Z0-9_]{3,30}$').hasMatch(v.trim())) {
                      return L10n.of(context).usernameRules;
                    }
                    if (_isUsernameAvailable == false) return L10n.of(context).usernameTaken;
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _passwordController,
                  label: L10n.of(context).password,
                  hint: L10n.of(context).passwordCreateHint,
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
                  validator: (v) => v!.length < 8 ? L10n.of(context).passwordTooShort : null,
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
                          color: active ? context.palette.brand : context.palette.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _confirmController,
                  label: L10n.of(context).confirmPassword,
                  hint: L10n.of(context).confirmPasswordHint,
                  prefixIcon: const Icon(LucideIcons.lock),
                  obscureText: _obscurePassword,
                  validator: (v) => v != _passwordController.text ? L10n.of(context).passwordsDontMatch : null,
                ),
                const SizedBox(height: 24),
                if (authProvider.errorMessage != null) AuthErrorBanner(authProvider.errorMessage!),
                ElevatedButton(
                  onPressed: authProvider.isLoading ? null : _signup,
                  child: authProvider.isLoading
                      ? SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(context.palette.onBrand),
                          ),
                        )
                      : Text(L10n.of(context).signUp),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(L10n.of(context).agreePrefix,
                        style: t.bodySmall?.copyWith(color: context.palette.textMuted)),
                    InkWell(
                      onTap: () => LegalScreen.open(context, LegalScreen.terms),
                      child: Text(L10n.of(context).terms,
                          style: t.bodySmall?.copyWith(color: context.palette.link)),
                    ),
                    Text(' and ',
                        style: t.bodySmall?.copyWith(color: context.palette.textMuted)),
                    InkWell(
                      onTap: () => LegalScreen.open(context, LegalScreen.privacy),
                      child: Text(L10n.of(context).privacyPolicy,
                          style: t.bodySmall?.copyWith(color: context.palette.link)),
                    ),
                    Text('.',
                        style: t.bodySmall?.copyWith(color: context.palette.textMuted)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      L10n.of(context).haveAccount,
                      style: t.bodyMedium?.copyWith(color: context.palette.textSecondary),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
                      child: Text(L10n.of(context).logIn),
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
