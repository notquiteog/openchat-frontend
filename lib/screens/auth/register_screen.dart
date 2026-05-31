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
      appBar: AppBar(title: const Text('Create Account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 32),
                const Icon(Icons.lock_outline, size: 64, color: Colors.blue),
                const SizedBox(height: 16),
                Text(
                  'OpenChat',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'End-to-end encrypted with PGP',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 40),

                TextFormField(
                  controller: _usernameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.alternate_email),
                    helperText: '3–32 lowercase letters, numbers, underscores',
                    border: OutlineInputBorder(),
                  ),
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Required';
                    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(v.toLowerCase())) {
                      return '3–32 lowercase alphanumeric characters or underscores';
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
                      icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.next,
                  validator: (v) {
                    if (v == null || v.length < 8) return 'Minimum 8 characters';
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
                    if (v != _passwordCtrl.text) return 'Passwords do not match';
                    return null;
                  },
                ),
                const SizedBox(height: 24),

                // Advanced: key type
                InkWell(
                  onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                  child: Row(
                    children: [
                      const Text('Advanced options'),
                      Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more),
                    ],
                  ),
                ),
                if (_showAdvanced) ...[
                  const SizedBox(height: 12),
                  const Text('PGP Key Algorithm', style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  RadioListTile<KeyType>(
                    value: KeyType.curve25519,
                    groupValue: _keyType,
                    onChanged: (v) => setState(() => _keyType = v!),
                    title: const Text('Curve25519 (ECC)'),
                    subtitle: const Text('Recommended — fast, modern, smaller keys'),
                  ),
                  RadioListTile<KeyType>(
                    value: KeyType.pqc,
                    groupValue: _keyType,
                    onChanged: (v) => setState(() => _keyType = v!),
                    title: const Text('ML-DSA-65 + ML-KEM-768 (Post-Quantum)'),
                    subtitle: const Text('Quantum-resistant hybrid key (FIPS 203/204)'),
                  ),
                  RadioListTile<KeyType>(
                    value: KeyType.rsa4096,
                    groupValue: _keyType,
                    onChanged: (v) => setState(() => _keyType = v!),
                    title: const Text('RSA-4096'),
                    subtitle: const Text('Traditional — wider compatibility'),
                  ),
                ],
                const SizedBox(height: 32),

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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create Account & Generate Keys'),
                ),
                const SizedBox(height: 16),

                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Already have an account? Sign in'),
                ),
                const SizedBox(height: 24),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha:0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.withValues(alpha:0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.shield, color: Colors.blue, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your PGP keys are generated on this device. '
                          'The private key never leaves your device — '
                          'only the public key is shared with the server.',
                          style: TextStyle(fontSize: 12, color: Colors.blue),
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
    );
  }
}
