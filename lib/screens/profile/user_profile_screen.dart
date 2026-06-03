import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../config/api_config.dart';
import '../../models/conversation.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

/// Public profile screen — shown when tapping a user's name/avatar anywhere in the app.
class UserProfileScreen extends StatefulWidget {
  final User user;
  const UserProfileScreen({super.key, required this.user});

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  late User _user;
  bool _loading = false;
  Future<List<Conversation>>? _sharedConversationsFuture;

  @override
  void initState() {
    super.initState();
    _user = widget.user;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sharedConversationsFuture ??= context
        .read<ApiService>()
        .getSharedConversations(_user.id);
  }

  bool get _isOwnProfile {
    final me = context.read<AuthProvider>().currentUser;
    return me?.id == _user.id;
  }

  bool get _viewerIsAdmin =>
      context.read<AuthProvider>().currentUser?.isSystemAdmin ?? false;

  Future<void> _ban() async {
    final api = context.read<ApiService>();
    final confirmed = await _confirm(
      'Ban @${_user.username}?',
      'Banned users cannot log in or send messages.',
    );
    if (!confirmed) return;
    setState(() => _loading = true);
    try {
      await api.banUser(_user.id);
      setState(() => _user = _user.copyWith(isBanned: true));
      _snack('User banned.');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _unban() async {
    setState(() => _loading = true);
    try {
      await context.read<ApiService>().unbanUser(_user.id);
      setState(() => _user = _user.copyWith(isBanned: false));
      _snack('User unbanned.');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _flagScammer() async {
    final api = context.read<ApiService>();
    final confirmed = await _confirm(
      'Flag @${_user.username} as scammer?',
      'A warning will be shown to everyone who views this profile.',
    );
    if (!confirmed) return;
    setState(() => _loading = true);
    try {
      await api.flagScammer(_user.id);
      setState(() => _user = _user.copyWith(isFlaggedScammer: true));
      _snack('Flagged as scammer.');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _unflagScammer() async {
    setState(() => _loading = true);
    try {
      await context.read<ApiService>().unflagScammer(_user.id);
      setState(() => _user = _user.copyWith(isFlaggedScammer: false));
      _snack('Scammer flag removed.');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _grantPremiumMonth() async {
    final api = context.read<ApiService>();
    final confirmed = await _confirm(
      'Give @${_user.username} Premium?',
      'This adds one month of Premium to the user account.',
    );
    if (!confirmed) return;
    setState(() => _loading = true);
    try {
      await api.grantPremiumMonth(_user.id);
      setState(() {
        final now = DateTime.now();
        final base =
            _user.premiumUntil != null && _user.premiumUntil!.isAfter(now)
            ? _user.premiumUntil!
            : now;
        _user = _user.copyWith(
          premiumUntil: base.add(const Duration(days: 30)),
        );
      });
      _snack('Premium granted for one month.');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _showPaymentSheet() async {
    final api = context.read<ApiService>();
    var providers = <String>['btc', 'xmr'];
    var balances = <Map<String, dynamic>>[];
    try {
      final status = await api.getBillingStatus();
      final enabled = ((status['providers'] as List?) ?? const [])
          .whereType<String>()
          .where((p) => p == 'btc' || p == 'xmr')
          .toList();
      if (enabled.isNotEmpty) providers = enabled;
      balances = (await api.getPaymentBalances())
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {}
    if (!mounted || !context.mounted) return;

    var payMode = true;
    var paymentSource = 'wallet';
    var provider = providers.first;
    var submitting = false;
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();

    double balanceFor(String provider) {
      for (final balance in balances) {
        if (balance['provider'] == provider) {
          return _asDouble(balance['available']);
        }
      }
      return 0;
    }

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetCtx) => StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            Future<void> submit() async {
              if (submitting) return;
              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
              if (amount <= 0) {
                _snack('Enter an amount.');
                return;
              }
              setSheet(() => submitting = true);
              try {
                if (payMode) {
                  if (paymentSource == 'wallet') {
                    if (amount > balanceFor(provider)) {
                      _snack('Not enough app wallet balance.');
                      return;
                    }
                    await api.sendPaymentTransfer(
                      toUserID: _user.id,
                      provider: provider,
                      amount: amount,
                      note: noteCtrl.text,
                    );
                  } else {
                    final result = await api.createExternalPaymentTransfer(
                      toUserID: _user.id,
                      provider: provider,
                      amount: amount,
                      note: noteCtrl.text,
                    );
                    if (!mounted || !sheetCtx.mounted) return;
                    Navigator.pop(sheetCtx);
                    final deposit = result['deposit'] as Map<String, dynamic>?;
                    if (deposit != null) _showExternalPaymentAddress(deposit);
                    return;
                  }
                } else {
                  await api.createPaymentRequest(
                    payerID: _user.id,
                    provider: provider,
                    amount: amount,
                    title: 'Payment request',
                    note: noteCtrl.text,
                  );
                }
                if (!mounted || !sheetCtx.mounted) return;
                Navigator.pop(sheetCtx);
                _snack(payMode ? 'Payment sent.' : 'Request sent.');
              } catch (e) {
                if (!mounted) return;
                _snack('Payment failed: $e');
              } finally {
                if (mounted) setSheet(() => submitting = false);
              }
            }

            final bottomInset = MediaQuery.of(sheetCtx).viewInsets.bottom;
            final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
            final available = balanceFor(provider);
            final canUseWallet =
                !payMode || (amount > 0 && available >= amount);
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + bottomInset),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              label: Text('Pay'),
                              icon: Icon(Icons.arrow_upward),
                            ),
                            ButtonSegment(
                              value: false,
                              label: Text('Request'),
                              icon: Icon(Icons.arrow_downward),
                            ),
                          ],
                          selected: {payMode},
                          onSelectionChanged: (next) =>
                              setSheet(() => payMode = next.first),
                        ),
                        const Spacer(),
                        Text(
                          _formatCrypto(available, provider),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: [
                        for (final p in providers)
                          ButtonSegment(value: p, label: Text(p.toUpperCase())),
                      ],
                      selected: {provider},
                      onSelectionChanged: (next) =>
                          setSheet(() => provider = next.first),
                    ),
                    const SizedBox(height: 12),
                    if (payMode) ...[
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'wallet',
                            label: const Text('App wallet'),
                            icon: const Icon(Icons.account_balance_wallet),
                            enabled: canUseWallet,
                          ),
                          const ButtonSegment(
                            value: 'external',
                            label: Text('External'),
                            icon: Icon(Icons.qr_code_2),
                          ),
                        ],
                        selected: {canUseWallet ? paymentSource : 'external'},
                        onSelectionChanged: (next) =>
                            setSheet(() => paymentSource = next.first),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) {
                        final nextAmount =
                            double.tryParse(amountCtrl.text.trim()) ?? 0;
                        setSheet(() {
                          if (payMode &&
                              paymentSource == 'wallet' &&
                              nextAmount > balanceFor(provider)) {
                            paymentSource = 'external';
                          }
                        });
                      },
                      decoration: InputDecoration(
                        labelText: 'Amount ${provider.toUpperCase()}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: noteCtrl,
                      maxLength: 160,
                      decoration: const InputDecoration(
                        labelText: 'Note',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: submitting ? null : submit,
                      icon: submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.payments_outlined),
                      label: Text(
                        payMode
                            ? 'Pay @${_user.username}'
                            : 'Request from @${_user.username}',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    } finally {
      amountCtrl.dispose();
      noteCtrl.dispose();
    }
  }

  void _showExternalPaymentAddress(Map<String, dynamic> deposit) {
    final address = deposit['crypto_address'] as String? ?? '';
    final provider = deposit['provider'] as String? ?? '';
    final amount = deposit['expected_amount'];
    final amountText = amount == null
        ? ''
        : '\n\nSend at least ${_formatCrypto(_asDouble(amount), provider)}.';
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Pay with ${provider.toUpperCase()}'),
        content: SelectableText('$address$amountText'),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: address));
              if (mounted && dialogCtx.mounted) Navigator.pop(dialogCtx);
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String content) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _showFingerprintQR() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('PGP Fingerprint'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: _user.keyFingerprint,
              version: QrVersions.auto,
              size: 220,
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _user.keyFingerprint));
                _snack('Fingerprint copied');
              },
              child: Text(
                _formatFingerprint(_user.keyFingerprint),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap fingerprint to copy  •  Scan QR to verify out-of-band',
              style: TextStyle(fontSize: 11, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatFingerprint(String fp) {
    // Insert space every 4 chars for readability: ABCD EFGH 1234 ...
    final clean = fp.toUpperCase();
    final buf = StringBuffer();
    for (var i = 0; i < clean.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write(' ');
      buf.write(clean[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isAdmin = _viewerIsAdmin;
    return Scaffold(
      appBar: GlassAppBar(
        title: Text('@${_user.username}'),
        actions: [
          if (isAdmin && !_isOwnProfile)
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'ban':
                    _ban();
                    break;
                  case 'unban':
                    _unban();
                    break;
                  case 'flag':
                    _flagScammer();
                    break;
                  case 'unflag':
                    _unflagScammer();
                    break;
                  case 'premium_month':
                    _grantPremiumMonth();
                    break;
                }
              },
              itemBuilder: (_) => [
                if (!_user.isBanned)
                  const PopupMenuItem(value: 'ban', child: Text('Ban user'))
                else
                  const PopupMenuItem(
                    value: 'unban',
                    child: Text('Unban user'),
                  ),
                if (!_user.isFlaggedScammer)
                  const PopupMenuItem(
                    value: 'flag',
                    child: Text('Flag as scammer'),
                  )
                else
                  const PopupMenuItem(
                    value: 'unflag',
                    child: Text('Remove scammer flag'),
                  ),
                const PopupMenuItem(
                  value: 'premium_month',
                  child: Text('Give Premium for 1 month'),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(0),
              children: [
                // ── Scammer warning ──────────────────────────────────────────
                if (_user.isFlaggedScammer)
                  Container(
                    color: Colors.red[700],
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber, color: Colors.white),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This user has been flagged as a scammer. Exercise caution.',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // ── Banned banner ─────────────────────────────────────────────
                if (_user.isBanned)
                  Container(
                    color: Colors.grey[800],
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.block, color: Colors.white70),
                        SizedBox(width: 8),
                        Text(
                          'This account has been banned.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),

                // ── Avatar + name ─────────────────────────────────────────────
                Container(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 50,
                        backgroundImage: _user.avatarUrl != null
                            ? CachedNetworkImageProvider(
                                ApiConfig.resolveMedia(_user.avatarUrl!),
                              )
                            : null,
                        backgroundColor: cs.primaryContainer,
                        child: _user.avatarUrl == null
                            ? Text(
                                _user.username[0].toUpperCase(),
                                style: TextStyle(
                                  fontSize: 36,
                                  color: cs.onPrimaryContainer,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '@${_user.username}',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (_user.isSystemAdmin)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Tooltip(
                                message: 'System admin',
                                child: Icon(
                                  Icons.verified,
                                  color: cs.primary,
                                  size: 20,
                                ),
                              ),
                            ),
                          if (_user.isBot)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: cs.secondaryContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'BOT',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: cs.onSecondaryContainer,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (_user.bio != null && _user.bio!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                          child: Text(
                            _user.bio!,
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.7),
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      if (!_isOwnProfile) ...[
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _showPaymentSheet,
                          icon: const Icon(Icons.payments_outlined),
                          label: const Text('Pay or request'),
                        ),
                      ],
                    ],
                  ),
                ),

                const Divider(height: 1),

                // ── Online status ─────────────────────────────────────────────
                ListTile(
                  leading: Icon(
                    Icons.circle,
                    size: 12,
                    color: _user.isOnline ? Colors.green : Colors.grey,
                  ),
                  title: Text(_user.isOnline ? 'Online' : 'Last seen recently'),
                  dense: true,
                ),

                if (_user.isPremium)
                  ListTile(
                    leading: const Icon(Icons.workspace_premium),
                    title: const Text('Premium active'),
                    subtitle: _user.premiumUntil == null
                        ? null
                        : Text(
                            'Until ${_user.premiumUntil!.toLocal().toString().split('.').first}',
                          ),
                    dense: true,
                  ),

                if (!_isOwnProfile) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Shared chats and channels',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  FutureBuilder<List<Conversation>>(
                    future: _sharedConversationsFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const ListTile(
                          leading: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          title: Text('Loading shared chats...'),
                          dense: true,
                        );
                      }
                      final sharedConversations =
                          snapshot.data ?? const <Conversation>[];
                      if (sharedConversations.isEmpty) {
                        return const ListTile(
                          leading: Icon(Icons.forum_outlined),
                          title: Text('No shared groups or channels'),
                          dense: true,
                        );
                      }
                      return Column(
                        children: [
                          for (final conv in sharedConversations.take(8))
                            ListTile(
                              leading: Icon(
                                conv.isChannel
                                    ? Icons.campaign_outlined
                                    : Icons.group_outlined,
                              ),
                              title: Text(conv.displayName('')),
                              subtitle: Text(
                                conv.isChannel ? 'Channel' : 'Group',
                              ),
                              dense: true,
                            ),
                        ],
                      );
                    },
                  ),
                ],

                // ── PGP fingerprint ───────────────────────────────────────────
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text('PGP Fingerprint'),
                  subtitle: Text(
                    _user.shortFingerprint,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.qr_code),
                    tooltip: 'Verify fingerprint',
                    onPressed: _user.keyFingerprint.isNotEmpty
                        ? _showFingerprintQR
                        : null,
                  ),
                ),

                const Divider(height: 1),
              ],
            ),
    );
  }
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

String _formatCrypto(double amount, String provider) {
  final decimals = provider == 'btc' ? 8 : 12;
  return '${amount.toStringAsFixed(decimals)} ${provider.toUpperCase()}';
}
