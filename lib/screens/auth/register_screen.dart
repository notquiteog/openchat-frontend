import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../crypto/pgp_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/key_provider.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  KeyType _keyType = KeyType.curve25519;
  bool _obscurePassword = true;
  bool _showAdvanced = false;

  @override
  void dispose() {
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

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SizedBox(
            key: const Key('auth-landing-hero'),
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFF6FBF8),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFFF6FBF8),
                    Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.08),
                  ],
                ),
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight - 40),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: () => Navigator.maybePop(context),
                                  child: const Text('Sign in'),
                                ),
                                const FilledButton(
                                  onPressed: null,
                                  child: Text('Sign up'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 48),
                          Text(
                            'OpenChat',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .displayMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Secure. Open. Encrypted.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: Colors.grey[700],
                                  letterSpacing: 1.4,
                                ),
                          ),
                          const SizedBox(height: 36),
                          Text(
                            'Create your account',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _usernameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Username',
                              prefixIcon: Icon(Icons.alternate_email),
                              helperText:
                                  '3-32 lowercase letters, numbers, underscores',
                              border: OutlineInputBorder(),
                            ),
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            validator: (v) {
                              if (v == null || v.isEmpty) return 'Required';
                              if (!RegExp(r'^[a-z0-9_]{3,32}$')
                                  .hasMatch(v.toLowerCase())) {
                                return '3-32 lowercase alphanumeric characters or underscores';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _passwordCtrl,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock),
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                icon: Icon(_obscurePassword
                                    ? Icons.visibility
                                    : Icons.visibility_off),
                                onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword),
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
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _confirmCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Confirm Password',
                              prefixIcon: Icon(Icons.lock_outline),
                              border: OutlineInputBorder(),
                            ),
                            obscureText: _obscurePassword,
                            validator: (v) {
                              if (v != _passwordCtrl.text) {
                                return 'Passwords do not match';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 24),
                          InkWell(
                            onTap: () =>
                                setState(() => _showAdvanced = !_showAdvanced),
                            child: Row(
                              children: [
                                const Text('Advanced options'),
                                Icon(_showAdvanced
                                    ? Icons.expand_less
                                    : Icons.expand_more),
                              ],
                            ),
                          ),
                          if (_showAdvanced) ...[
                            const SizedBox(height: 12),
                            const Text('PGP Key Algorithm',
                                style: TextStyle(fontWeight: FontWeight.w500)),
                            const SizedBox(height: 8),
                            RadioGroup<KeyType>(
                              groupValue: _keyType,
                              onChanged: (v) => setState(() => _keyType = v!),
                              child: const Column(
                                children: [
                                  RadioListTile<KeyType>(
                                    value: KeyType.curve25519,
                                    title: Text('Curve25519 (ECC)'),
                                    subtitle: Text(
                                        'Recommended - fast, modern, smaller keys'),
                                  ),
                                  RadioListTile<KeyType>(
                                    value: KeyType.pqc,
                                    title: Text(
                                        'ML-DSA-65 + ML-KEM-768 (Post-Quantum)'),
                                    subtitle: Text(
                                        'Quantum-resistant hybrid key (FIPS 203/204)'),
                                  ),
                                  RadioListTile<KeyType>(
                                    value: KeyType.rsa4096,
                                    title: Text('RSA-4096'),
                                    subtitle: Text(
                                        'Traditional - wider compatibility'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 28),
                          if (auth.error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Text(
                                auth.error!,
                                style: const TextStyle(color: Colors.red),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          FilledButton(
                            onPressed: auth.isLoading ? null : _register,
                            child: auth.isLoading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Text('Create account'),
                          ),
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: () => Navigator.maybePop(context),
                            child:
                                const Text('Already have an account? Sign in'),
                          ),
                          const SizedBox(height: 24),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: Colors.blue.withValues(alpha: 0.3)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.shield,
                                    color: Colors.blue, size: 18),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Your PGP keys are generated on this device. '
                                    'The private key never leaves your device. '
                                    'Only the public key is shared with the server.',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.blue),
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
              ),
            ),
          );
        },
      ),
    );
  }
}
