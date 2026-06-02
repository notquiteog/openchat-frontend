import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/secure_storage_warning.dart';
import '../settings/pgp_keys_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    await context.read<AuthProvider>().login(
          username: _usernameCtrl.text.trim().toLowerCase(),
          password: _passwordCtrl.text,
        );
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
                                  onPressed: null,
                                  child: const Text('Sign in'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => const RegisterScreen()),
                                  ),
                                  child: const Text('Sign up'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 56),
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
                          const SizedBox(height: 48),
                          TextFormField(
                            controller: _usernameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Username',
                              prefixIcon: Icon(Icons.alternate_email),
                              border: OutlineInputBorder(),
                            ),
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            validator: (v) =>
                                v?.isEmpty == true ? 'Required' : null,
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
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _login(),
                            validator: (v) =>
                                v?.isEmpty == true ? 'Required' : null,
                          ),
                          const SizedBox(height: 28),
                          if (auth.storageWarning != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: SecureStorageWarning(
                                message: auth.storageWarning!,
                              ),
                            ),
                          if (auth.error != null &&
                              auth.error != auth.storageWarning)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Text(
                                auth.error!,
                                style: const TextStyle(color: Colors.red),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          FilledButton(
                            onPressed: auth.isLoading ? null : _login,
                            child: auth.isLoading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : const Text('Sign in'),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const RegisterScreen()),
                            ),
                            child: const Text('Create your account'),
                          ),
                          const SizedBox(height: 24),
                          const Divider(),
                          TextButton.icon(
                            icon: const Icon(Icons.vpn_key_outlined),
                            label: const Text('Import existing PGP key'),
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const PgpKeysScreen()),
                            ),
                          ),
                          Text(
                            'Sign-in requires your private key to be on this device.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Colors.grey),
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
