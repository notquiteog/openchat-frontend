import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../crypto/pgp_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/key_provider.dart';
import '../../widgets/glass.dart';
import '../../widgets/gold_sand_background.dart';
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
  bool _publicDiscovery = true;

  late final AnimationController _entranceCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _entranceCtrl,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
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
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    final username = _usernameCtrl.text.trim().toLowerCase();
    await auth.register(
      username: username,
      password: _passwordCtrl.text,
      publicDiscovery: _publicDiscovery,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: GoldSandBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: FadeTransition(
                opacity: _fade,
                child: SlideTransition(
                  position: _slide,
                  child: GlassContainer(
                    key: const Key('auth-register-hero'),
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
                            padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                            child: Row(
                              children: [
                                // Back arrow
                                IconButton(
                                  icon: const Icon(
                                    Icons.arrow_back_ios_new_rounded,
                                  ),
                                  onPressed: () => Navigator.pop(context),
                                  style: IconButton.styleFrom(
                                    foregroundColor: scheme.onSurface
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Logo
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: [
                                      BoxShadow(
                                        color: scheme.primary.withValues(
                                          alpha: 0.30,
                                        ),
                                        blurRadius: 16,
                                        spreadRadius: -2,
                                        offset: const Offset(0, 6),
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
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Create account',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: -0.3,
                                            ),
                                      ),
                                      Text(
                                        'Your keys stay on your device',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurface
                                                  .withValues(alpha: 0.50),
                                            ),
                                      ),
                                    ],
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
                            padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
                            child: Form(
                              key: _formKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextFormField(
                                    controller: _usernameCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Username',
                                      prefixIcon: Icon(
                                        Icons.alternate_email_rounded,
                                      ),
                                      helperText:
                                          'Search visibility can be changed later',
                                    ),
                                    autocorrect: false,
                                    textInputAction: TextInputAction.next,
                                    validator: (v) {
                                      final value =
                                          v?.trim().toLowerCase() ?? '';
                                      if (value.isEmpty) {
                                        return 'Username required';
                                      }
                                      if (!RegExp(
                                        r'^[a-z0-9_]{3,32}$',
                                      ).hasMatch(value)) {
                                        return '3–32 lowercase alphanumeric or underscores';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  GlassListTile(
                                    title: const Text('Public discovery',
                                        style: TextStyle(fontWeight: FontWeight.w600)),
                                    subtitle: const Text(
                                      'Allow username search for this account',
                                    ),
                                    trailing: GlassSwitch(
                                      value: _publicDiscovery,
                                      onChanged: (value) => setState(
                                        () => _publicDiscovery = value,
                                      ),
                                      activeColor: Theme.of(context).colorScheme.primary,
                                      enableHaptics: true,
                                    ),
                                    onTap: () => setState(
                                      () => _publicDiscovery = !_publicDiscovery,
                                    ),
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
                                    textInputAction: TextInputAction.next,
                                    validator: (v) {
                                      if (v == null || v.length < 8) {
                                        return 'Minimum 8 characters';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _confirmCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Confirm password',
                                      prefixIcon: Icon(
                                        Icons.lock_outline_rounded,
                                      ),
                                    ),
                                    obscureText: _obscurePassword,
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) => _register(),
                                    validator: (v) {
                                      if (v != _passwordCtrl.text) {
                                        return 'Passwords do not match';
                                      }
                                      return null;
                                    },
                                  ),

                                  // Advanced toggle
                                  const SizedBox(height: 16),
                                  InkWell(
                                    onTap: () => setState(
                                      () => _showAdvanced = !_showAdvanced,
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _showAdvanced
                                                ? Icons.expand_less_rounded
                                                : Icons.expand_more_rounded,
                                            color: scheme.primary,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Advanced options',
                                            style: TextStyle(
                                              color: scheme.primary,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (_showAdvanced) ...[
                                    const SizedBox(height: 10),
                                    Text(
                                      'PGP Key Algorithm',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurface.withValues(
                                          alpha: 0.65,
                                        ),
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Column(
                                      children: [
                                        for (final keyType
                                            in KeyType.accountCreationOptions)
                                          GlassListTile(
                                            leading: Icon(
                                              keyType == _keyType
                                                  ? Icons.radio_button_checked
                                                  : Icons.radio_button_unchecked,
                                              color: keyType == _keyType
                                                  ? Theme.of(context).colorScheme.primary
                                                  : null,
                                              size: 20,
                                            ),
                                            title: Text(keyType.title,
                                                style: const TextStyle(fontWeight: FontWeight.w600)),
                                            subtitle: Text(keyType.subtitle),
                                            onTap: () => setState(() => _keyType = keyType),
                                          ),
                                      ],
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
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 14,
                                      ),
                                      child: _ErrorBanner(message: auth.error!),
                                    ),

                                  // Create button
                                  Row(
                                    children: [
                                      Expanded(
                                        child: GlassButtonWidget(
                                          onPressed: auth.isLoading
                                              ? null
                                              : _register,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 16,
                                          ),
                                          child: auth.isLoading
                                              ? const GlassProgressIndicator.circular(size: 20, strokeWidth: 2)
                                              : const Text('Create account'),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),

                                  // E2E privacy notice
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.primary.withValues(
                                        alpha: 0.07,
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: scheme.primary.withValues(
                                          alpha: 0.16,
                                        ),
                                        width: 0.7,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.shield_outlined,
                                          color: scheme.primary,
                                          size: 17,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            'PGP keys are generated on-device. '
                                            'Your private key never leaves this device.',
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

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.error.withValues(alpha: 0.26),
          width: 0.7,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.error, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
