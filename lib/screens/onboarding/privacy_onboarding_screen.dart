import 'package:flutter/material.dart';

import '../../models/conversation.dart';
import '../../widgets/glass.dart';

class PrivacyOnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const PrivacyOnboardingScreen({super.key, required this.onComplete});

  @override
  State<PrivacyOnboardingScreen> createState() =>
      _PrivacyOnboardingScreenState();
}

class _PrivacyOnboardingScreenState extends State<PrivacyOnboardingScreen> {
  late final PageController _pageController;
  int _page = 0;

  static const _pages = [
    _OnboardingPageData(
      icon: Icons.badge_outlined,
      title: 'Username and display name',
      body:
          'Your username is your unique @ handle. People can use it to find you when public discovery is enabled. Your display name is cosmetic and can change without changing your @ handle.',
    ),
    _OnboardingPageData(
      icon: Icons.visibility_off_outlined,
      title: 'Sealed sender',
      body:
          'In encrypted chats, OpenChat can post without storing your account as the visible sender. Recipients verify the real sender after decryption, so the server sees less metadata.',
    ),
    _OnboardingPageData(
      icon: Icons.lock_outline_rounded,
      title: 'PGP chats',
      body:
          'PGP mode encrypts each message on your device for the current recipient keys. The server stores ciphertext and cannot read the message body or attachments.',
      mode: EncryptionMode.pgp,
    ),
    _OnboardingPageData(
      icon: Icons.groups_2_outlined,
      title: 'MLS chats',
      body:
          'MLS mode uses a group ratchet for stronger group messaging. It is best for modern encrypted groups where members can rotate through device and membership changes.',
      mode: EncryptionMode.mls,
    ),
    _OnboardingPageData(
      icon: Icons.lock_open_outlined,
      title: 'Plaintext chats',
      body:
          'Plaintext mode is encryption off. Use it only when you intentionally want server-readable chat content for a specific workflow.',
      mode: EncryptionMode.plaintext,
      warning: true,
    ),
    _OnboardingPageData(
      icon: Icons.shield_outlined,
      title: 'Your privacy defaults',
      body:
          'Push previews are off by default, private state stays encrypted on this device, and you can review keys, sessions, and metadata controls in the Trust Center.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _pages.length - 1) {
      widget.onComplete();
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = _pages[_page];
    return Scaffold(
      body: LiquidMeshBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(
                  children: [
                    Image.asset(
                      'assets/images/logo.png',
                      width: 30,
                      height: 30,
                      errorBuilder: (_, _, _) =>
                          Icon(Icons.shield_outlined, color: scheme.primary),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'OpenChat',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    _StepPill(current: _page + 1, total: _pages.length),
                  ],
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _pages.length,
                  onPageChanged: (value) => setState(() => _page = value),
                  itemBuilder: (context, index) {
                    final data = _pages[index];
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: GlassCard(
                            padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _pageColor(
                                      context,
                                      data,
                                    ).withValues(alpha: 0.13),
                                  ),
                                  child: Icon(
                                    data.icon,
                                    size: 34,
                                    color: _pageColor(context, data),
                                  ),
                                ),
                                const SizedBox(height: 22),
                                Text(
                                  data.title,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  data.body,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        height: 1.42,
                                        color: scheme.onSurface.withValues(
                                          alpha: 0.76,
                                        ),
                                      ),
                                ),
                                if (data.mode != null) ...[
                                  const SizedBox(height: 18),
                                  _EncryptionModeChip(
                                    mode: data.mode!,
                                    warning: data.warning,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            for (var i = 0; i < _pages.length; i++)
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: i == _page ? 24 : 8,
                                height: 8,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  color: i == _page
                                      ? _pageColor(context, page)
                                      : scheme.outlineVariant.withValues(
                                          alpha: 0.5,
                                        ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _next,
                        icon: Icon(
                          _page == _pages.length - 1
                              ? Icons.check_rounded
                              : Icons.arrow_forward_rounded,
                        ),
                        label: Text(
                          _page == _pages.length - 1 ? 'Finish' : 'Next',
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
    );
  }

  Color _pageColor(BuildContext context, _OnboardingPageData page) {
    final scheme = Theme.of(context).colorScheme;
    if (page.warning) return scheme.error;
    return switch (page.mode) {
      EncryptionMode.mls => scheme.tertiary,
      EncryptionMode.pgp => Colors.green,
      EncryptionMode.plaintext => scheme.error,
      null => scheme.primary,
    };
  }
}

class _EncryptionModeChip extends StatelessWidget {
  final EncryptionMode mode;
  final bool warning;

  const _EncryptionModeChip({required this.mode, this.warning = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = warning
        ? scheme.error
        : mode == EncryptionMode.mls
        ? scheme.tertiary
        : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '${mode.shortLabel} mode',
        style: TextStyle(color: color, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _StepPill extends StatelessWidget {
  final int current;
  final int total;

  const _StepPill({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$current/$total',
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }
}

class _OnboardingPageData {
  final IconData icon;
  final String title;
  final String body;
  final EncryptionMode? mode;
  final bool warning;

  const _OnboardingPageData({
    required this.icon,
    required this.title,
    required this.body,
    this.mode,
    this.warning = false,
  });
}
