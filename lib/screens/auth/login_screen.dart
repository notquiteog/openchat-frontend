import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/glass.dart';
import '../../widgets/gold_sand_background.dart';
import '../../widgets/secure_storage_warning.dart';
import '../settings/device_pairing_screen.dart';
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
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _twoFactorCtrl = TextEditingController();
  bool _obscurePassword = true;

  late final AnimationController _entranceCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );
  late final Animation<double> _entranceFade = CurvedAnimation(
    parent: _entranceCtrl,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _entranceSlide = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    _entranceCtrl.forward();
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    _twoFactorCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    await context.read<AuthProvider>().login(
      identifier: _identifierCtrl.text.trim().toLowerCase(),
      password: _passwordCtrl.text,
      twoFactorPassword: _twoFactorCtrl.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: GoldSandBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: FadeTransition(
                opacity: _entranceFade,
                child: SlideTransition(
                  position: _entranceSlide,
                  child: GlassContainer(
                    key: const Key('auth-landing-hero'),
                    shape: LiquidRoundedSuperellipse(borderRadius: 36),
                    allowElevation: true,
                    glowIntensity: 0.07,
                    padding: EdgeInsets.zero,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // ── Brand section ─────────────────────────────────
                          Padding(
                            padding: const EdgeInsets.fromLTRB(28, 36, 28, 28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Logo
                                Container(
                                  width: 80,
                                  height: 80,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(22),
                                    boxShadow: [
                                      BoxShadow(
                                        color: scheme.primary.withValues(
                                          alpha: 0.35,
                                        ),
                                        blurRadius: 28,
                                        spreadRadius: -4,
                                        offset: const Offset(0, 10),
                                      ),
                                    ],
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: Image.asset(
                                    'assets/images/logo.png',
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      color: scheme.primary,
                                      child: const Icon(
                                        Icons.chat_bubble_outline_rounded,
                                        color: Colors.white,
                                        size: 40,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  'OpenChat',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0,
                                      ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  'Secure · Open · Encrypted',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurface.withValues(
                                          alpha: 0.50,
                                        ),
                                        letterSpacing: 1.0,
                                        fontWeight: FontWeight.w500,
                                      ),
                                ),
                              ],
                            ),
                          ),

                          // Divider
                          Divider(
                            height: 1,
                            thickness: 0.5,
                            color: (isDark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.08),
                          ),

                          // ── Form section ──────────────────────────────────
                          Padding(
                            padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
                            child: Form(
                              key: _formKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Sign in',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 20),
                                  TextFormField(
                                    controller: _identifierCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Username or account ID',
                                      prefixIcon: Icon(Icons.badge_outlined),
                                    ),
                                    autocorrect: false,
                                    textInputAction: TextInputAction.next,
                                    validator: (v) =>
                                        v?.isEmpty == true ? 'Required' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _passwordCtrl,
                                    decoration: InputDecoration(
                                      labelText: 'Password',
                                      prefixIcon: const Icon(
                                        Icons.lock_outline_rounded,
                                      ),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_outlined
                                              : Icons.visibility_off_outlined,
                                        ),
                                        onPressed: () => setState(
                                          () => _obscurePassword =
                                              !_obscurePassword,
                                        ),
                                      ),
                                    ),
                                    obscureText: _obscurePassword,
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) => _login(),
                                    validator: (v) =>
                                        v?.isEmpty == true ? 'Required' : null,
                                  ),
                                  if (auth.twoFactorRequired ||
                                      _twoFactorCtrl.text.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller: _twoFactorCtrl,
                                      decoration: const InputDecoration(
                                        labelText: '2FA code',
                                        prefixIcon: Icon(
                                          Icons.security_outlined,
                                        ),
                                      ),
                                      obscureText: true,
                                      keyboardType: TextInputType.number,
                                      textInputAction: TextInputAction.done,
                                      onChanged: (_) => setState(() {}),
                                      onFieldSubmitted: (_) => _login(),
                                    ),
                                  ],
                                  const SizedBox(height: 22),

                                  // Errors
                                  if (auth.storageWarning != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 14,
                                      ),
                                      child: SecureStorageWarning(
                                        message: auth.storageWarning!,
                                      ),
                                    ),
                                  if (auth.error != null &&
                                      auth.error != auth.storageWarning)
                                    _ErrorBox(message: auth.error!),

                                  // Sign-in button
                                  Row(
                                    children: [
                                      Expanded(
                                        child: GlassButtonWidget(
                                          onPressed: auth.isLoading
                                              ? null
                                              : _login,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 16,
                                          ),
                                          child: auth.isLoading
                                              ? const GlassProgressIndicator.circular(
                                                  size: 20,
                                                  strokeWidth: 2,
                                                )
                                              : const Text('Sign in'),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: GlassButtonWidget(
                                          onPressed: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const RegisterScreen(),
                                            ),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 16,
                                          ),
                                          child: const Text(
                                            'Create your account',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 20),
                                  Divider(
                                    color: Colors.white.withValues(alpha: 0.12),
                                    height: 1,
                                  ),
                                  const SizedBox(height: 14),
                                  TextButton.icon(
                                    icon: const Icon(
                                      Icons.vpn_key_outlined,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Import existing PGP key',
                                    ),
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => const PgpKeysScreen(),
                                      ),
                                    ),
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(
                                      Icons.qr_code_scanner_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Scan pairing QR'),
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const DevicePairingScreen(
                                              initialMode:
                                                  DevicePairingMode.scan,
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Sign-in requires your private key on this device.',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: scheme.onSurface.withValues(
                                            alpha: 0.38,
                                          ),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        tint: scheme.error,
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.error, size: 17),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: scheme.error,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
