import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/glass.dart';
import '../../widgets/secure_storage_warning.dart';
import '../settings/pgp_keys_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _twoFactorCtrl = TextEditingController();
  bool _obscurePassword = true;

  late final AnimationController _entranceCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 680),
  );
  late final Animation<double> _entranceFade =
      CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutCubic);
  late final Animation<double> _entranceScale = Tween<double>(
    begin: 0.88,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutBack));

  @override
  void initState() {
    super.initState();
    _entranceCtrl.forward();
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _twoFactorCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    await context.read<AuthProvider>().login(
      username: _usernameCtrl.text.trim().toLowerCase(),
      password: _passwordCtrl.text,
      twoFactorPassword: _twoFactorCtrl.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: LiquidMeshBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: FadeTransition(
                opacity: _entranceFade,
                child: ScaleTransition(
                  scale: _entranceScale,
                  child: GlassContainer(
                key: const Key('auth-landing-hero'),
                shape: LiquidRoundedSuperellipse(borderRadius: 36),
                allowElevation: true,
                glowIntensity: 0.06,
                padding: const EdgeInsets.fromLTRB(28, 32, 28, 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Logo + wordmark
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      scheme.primary,
                                      scheme.tertiary,
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: scheme.primary.withValues(alpha: 0.42),
                                      blurRadius: 24,
                                      spreadRadius: -4,
                                      offset: const Offset(0, 10),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.lock_outline_rounded,
                                  color: Colors.white,
                                  size: 34,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'OpenChat',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Secure · Open · Encrypted',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: scheme.onSurface
                                          .withValues(alpha: 0.55),
                                      letterSpacing: 0.8,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 36),
                        // Username
                        TextFormField(
                          controller: _usernameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            prefixIcon: Icon(Icons.alternate_email_rounded),
                          ),
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          validator: (v) =>
                              v?.isEmpty == true ? 'Required' : null,
                        ),
                        const SizedBox(height: 14),
                        // Password
                        TextFormField(
                          controller: _passwordCtrl,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                          ),
                          obscureText: _obscurePassword,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _login(),
                          validator: (v) =>
                              v?.isEmpty == true ? 'Required' : null,
                        ),
                        // 2FA (conditional)
                        if (auth.twoFactorRequired ||
                            _twoFactorCtrl.text.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: _twoFactorCtrl,
                            decoration: const InputDecoration(
                              labelText: '2FA password',
                              prefixIcon:
                                  Icon(Icons.security_outlined),
                            ),
                            obscureText: true,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => setState(() {}),
                            onFieldSubmitted: (_) => _login(),
                          ),
                        ],
                        const SizedBox(height: 24),
                        // Warnings
                        if (auth.storageWarning != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: SecureStorageWarning(
                              message: auth.storageWarning!,
                            ),
                          ),
                        if (auth.error != null &&
                            auth.error != auth.storageWarning)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.error.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: scheme.error.withValues(alpha: 0.28),
                                  width: 0.7,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.error_outline_rounded,
                                    color: scheme.error,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      auth.error!,
                                      style: TextStyle(
                                        color: scheme.error,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        // Sign in button
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            onPressed: auth.isLoading ? null : _login,
                            style: FilledButton.styleFrom(
                              shape: const StadiumBorder(),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            child: auth.isLoading
                                ? SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: scheme.onPrimary,
                                    ),
                                  )
                                : const Text('Sign in'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Create account button
                        SizedBox(
                          height: 52,
                          child: FilledButton.tonal(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const RegisterScreen(),
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              shape: const StadiumBorder(),
                            ),
                            child: const Text('Create your account'),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Divider(
                          color: Colors.white.withValues(alpha: 0.12),
                          height: 1,
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          icon: const Icon(Icons.vpn_key_outlined, size: 17),
                          label: const Text('Import existing PGP key'),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const PgpKeysScreen(),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Sign-in requires your private key to be on this device.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: scheme.onSurface.withValues(alpha: 0.40),
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
                ), // ScaleTransition
                ), // FadeTransition
            ),
          ),
        ),
      ),
    );
  }
}
