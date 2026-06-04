import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../crypto/pgp_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/key_provider.dart';
import '../../widgets/glass.dart';
import '../../widgets/secure_storage_warning.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  KeyType _keyType = KeyType.defaultType;
  bool _obscurePassword = true;
  bool _showAdvanced = false;

  late final AnimationController _entranceCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 680),
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutCubic);
  late final Animation<double> _scale = Tween<double>(begin: 0.88, end: 1.0)
      .animate(CurvedAnimation(
          parent: _entranceCtrl, curve: Curves.easeOutBack));

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
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    await auth.register(
      username: _usernameCtrl.text.trim().toLowerCase(),
      password: _passwordCtrl.text,
      keyType: _keyType,
    );
    if (mounted && auth.isAuthenticated) {
      await context.read<KeyProvider>().load();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    }
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
                opacity: _fade,
                child: ScaleTransition(
                  scale: _scale,
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
                        // Logo
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      scheme.tertiary,
                                      scheme.primary,
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: scheme.primary.withValues(alpha: 0.40),
                                      blurRadius: 22,
                                      spreadRadius: -4,
                                      offset: const Offset(0, 10),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.person_add_outlined,
                                  color: Colors.white,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                'Create account',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Your keys stay on your device',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: scheme.onSurface.withValues(alpha: 0.50),
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),
                        // Username
                        TextFormField(
                          controller: _usernameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            prefixIcon: Icon(Icons.alternate_email_rounded),
                            helperText:
                                '3-32 lowercase letters, numbers, underscores',
                          ),
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          validator: (v) {
                            if (v == null || v.isEmpty) return 'Required';
                            if (!RegExp(r'^[a-z0-9_]{3,32}$')
                                .hasMatch(v.toLowerCase())) {
                              return '3-32 lowercase alphanumeric or underscores';
                            }
                            return null;
                          },
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
                          textInputAction: TextInputAction.next,
                          validator: (v) {
                            if (v == null || v.length < 8) {
                              return 'Minimum 8 characters';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        // Confirm password
                        TextFormField(
                          controller: _confirmCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Confirm password',
                            prefixIcon: Icon(Icons.lock_outline_rounded),
                          ),
                          obscureText: _obscurePassword,
                          validator: (v) {
                            if (v != _passwordCtrl.text) {
                              return 'Passwords do not match';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 18),
                        // Advanced toggle
                        InkWell(
                          onTap: () =>
                              setState(() => _showAdvanced = !_showAdvanced),
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  'Advanced options',
                                  style: TextStyle(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  _showAdvanced
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded,
                                  color: scheme.primary,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_showAdvanced) ...[
                          const SizedBox(height: 12),
                          Text(
                            'PGP Key Algorithm',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface.withValues(alpha: 0.7),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 8),
                          RadioGroup<KeyType>(
                            groupValue: _keyType,
                            onChanged: (v) => setState(() => _keyType = v!),
                            child: Column(
                              children: [
                                for (final keyType in KeyType.accountCreationOptions)
                                  RadioListTile<KeyType>(
                                    value: keyType,
                                    title: Text(keyType.title),
                                    subtitle: Text(keyType.subtitle),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 22),
                        // Errors
                        if (auth.storageWarning != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: SecureStorageWarning(
                              message: auth.storageWarning!,
                            ),
                          ),
                        if (auth.error != null && auth.error != auth.storageWarning)
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
                        // Create button
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            onPressed: auth.isLoading ? null : _register,
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
                                : const Text('Create account'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Privacy notice
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: scheme.primary.withValues(alpha: 0.18),
                              width: 0.7,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.shield_outlined,
                                color: scheme.primary,
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'PGP keys are generated on this device. '
                                  'Your private key never leaves your device.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.primary,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
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
