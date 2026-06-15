import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../models/conversation.dart';
import '../../models/key_trust_pin.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/websocket_service.dart';
import '../../utils/identity_qr.dart';
import '../../widgets/glass.dart';
import '../../widgets/key_verification_badge.dart';
import '../settings/identity_qr_scanner_screen.dart';

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
  StreamSubscription<WsEvent>? _wsSub;
  KeyTrustPin? _keyTrustPin;
  String? _keyTrustPinUserId;

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
    if (_wsSub == null) {
      _fetchFreshUser();
      _wsSub = context.read<WebSocketService>().events.listen(_onWsEvent);
    }
    unawaited(_loadKeyTrustPin());
  }

  void _fetchFreshUser() async {
    try {
      final fresh = await context.read<ApiService>().getUserByUsername(
        _user.username,
      );
      if (mounted) {
        setState(() => _user = fresh);
        unawaited(_loadKeyTrustPin());
      }
    } catch (_) {}
  }

  Future<void> _loadKeyTrustPin() async {
    if (_isOwnProfile) {
      if (_keyTrustPin != null && mounted) {
        setState(() {
          _keyTrustPin = null;
          _keyTrustPinUserId = null;
        });
      }
      return;
    }
    final userId = _user.id;
    if (_keyTrustPinUserId == userId) return;
    _keyTrustPinUserId = userId;
    final pin = await context.read<SecureStorageService>().getKeyTrustPin(
      userId,
    );
    if (!mounted || _keyTrustPinUserId != userId) return;
    setState(() => _keyTrustPin = pin);
  }

  void _onWsEvent(WsEvent event) {
    if (event.type != WsEventType.userOnline &&
        event.type != WsEventType.userOffline) {
      return;
    }
    final userId = event.data['user_id'] as String?;
    if (userId != _user.id || !mounted) return;
    setState(() {
      if (event.type == WsEventType.userOnline) {
        _user = _user.copyWith(lastSeen: DateTime.now());
      } else {
        // Push lastSeen into the past so isOnline immediately returns false
        _user = _user.copyWith(
          lastSeen: DateTime.now().subtract(const Duration(minutes: 10)),
        );
      }
    });
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }

  bool get _isOwnProfile {
    final me = context.read<AuthProvider>().currentUser;
    return me?.id == _user.id;
  }

  bool get _viewerIsAdmin =>
      context.read<AuthProvider>().currentUser?.isSystemAdmin ?? false;

  void _showAdminMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            if (!_user.isBanned)
              _ProfileMenuTile(
                icon: Icons.block_rounded,
                label: 'Ban user',
                color: Colors.red,
                onTap: () {
                  Navigator.pop(context);
                  _ban();
                },
              )
            else
              _ProfileMenuTile(
                icon: Icons.check_circle_outline_rounded,
                label: 'Unban user',
                onTap: () {
                  Navigator.pop(context);
                  _unban();
                },
              ),
            if (!_user.isFlaggedScammer)
              _ProfileMenuTile(
                icon: Icons.flag_outlined,
                label: 'Flag as scammer',
                color: Colors.orange,
                onTap: () {
                  Navigator.pop(context);
                  _flagScammer();
                },
              )
            else
              _ProfileMenuTile(
                icon: Icons.flag_outlined,
                label: 'Remove scammer flag',
                onTap: () {
                  Navigator.pop(context);
                  _unflagScammer();
                },
              ),
            _ProfileMenuTile(
              icon: Icons.workspace_premium_outlined,
              label: 'Give Premium for 1 month',
              onTap: () {
                Navigator.pop(context);
                _grantPremiumMonth();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

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
    var amountUnit = 'crypto';
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
        backgroundColor: Colors.transparent,
        builder: (sheetCtx) => StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            Future<void> submit() async {
              if (submitting) return;
              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
              if (amount <= 0) {
                _snack('Enter an amount.');
                return;
              }
              final isCryptoAmount = amountUnit == 'crypto';
              final fiatCurrency = isCryptoAmount
                  ? null
                  : amountUnit.toUpperCase();
              final chat = context.read<ChatProvider>();
              setSheet(() => submitting = true);
              try {
                if (payMode) {
                  final useWallet =
                      paymentSource == 'wallet' &&
                      (!isCryptoAmount || amount <= balanceFor(provider));
                  if (useWallet) {
                    if (isCryptoAmount && amount > balanceFor(provider)) {
                      _snack('Not enough app wallet balance.');
                      return;
                    }
                    final result = await api.sendPaymentTransfer(
                      toUserID: _user.id,
                      provider: provider,
                      amount: isCryptoAmount ? amount : null,
                      fiatAmount: isCryptoAmount ? null : amount,
                      fiatCurrency: fiatCurrency,
                      note: noteCtrl.text,
                    );
                    final transfer =
                        result['transfer'] as Map<String, dynamic>?;
                    if (transfer != null) {
                      final conv = await chat.openDM(_user.id);
                      await chat.sendPaymentArtifact(
                        convID: conv.id,
                        kind: 'payment_transfer',
                        payload: {
                          'kind': 'payment_transfer',
                          'transfer': transfer,
                        },
                      );
                    }
                  } else {
                    final result = await api.createExternalPaymentTransfer(
                      toUserID: _user.id,
                      provider: provider,
                      amount: isCryptoAmount ? amount : null,
                      fiatAmount: isCryptoAmount ? null : amount,
                      fiatCurrency: fiatCurrency,
                      note: noteCtrl.text,
                    );
                    final deposit = result['deposit'] as Map<String, dynamic>?;
                    if (deposit != null) {
                      final conv = await chat.openDM(_user.id);
                      await chat.sendPaymentArtifact(
                        convID: conv.id,
                        kind: 'invoice',
                        payload: {
                          'kind': 'invoice',
                          'invoice': {
                            'id': deposit['id'],
                            'title': 'External payment',
                            'description': noteCtrl.text.trim(),
                            'provider': deposit['provider'],
                            'crypto_amount': deposit['expected_amount'],
                            'crypto_address': deposit['crypto_address'],
                            'status': deposit['status'],
                          },
                        },
                      );
                    }
                    if (!mounted || !sheetCtx.mounted) return;
                    Navigator.pop(sheetCtx);
                    if (deposit != null) _showExternalPaymentAddress(deposit);
                    return;
                  }
                } else {
                  final result = await api.createPaymentRequest(
                    payerID: _user.id,
                    provider: provider,
                    amount: isCryptoAmount ? amount : null,
                    fiatAmount: isCryptoAmount ? null : amount,
                    fiatCurrency: fiatCurrency,
                    title: 'Payment request',
                    note: noteCtrl.text,
                  );
                  final request = result['request'] as Map<String, dynamic>?;
                  if (request != null) {
                    final conv = await chat.openDM(_user.id);
                    await chat.sendPaymentArtifact(
                      convID: conv.id,
                      kind: 'payment_request',
                      payload: {'kind': 'payment_request', 'request': request},
                    );
                  }
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

            final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
            final available = balanceFor(provider);
            final isCryptoAmount = amountUnit == 'crypto';
            final canUseWallet =
                !payMode ||
                !isCryptoAmount ||
                amount <= 0 ||
                available >= amount;
            return GlassBottomSheetFrame(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
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
                    onSelectionChanged: (next) => setSheet(() {
                      provider = next.first;
                      if (payMode &&
                          amountUnit == 'crypto' &&
                          paymentSource == 'wallet' &&
                          amount > balanceFor(provider)) {
                        paymentSource = 'external';
                      }
                    }),
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
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: 'crypto',
                        label: Text(provider.toUpperCase()),
                      ),
                      const ButtonSegment(value: 'usd', label: Text('USD')),
                      const ButtonSegment(value: 'eur', label: Text('EUR')),
                    ],
                    selected: {amountUnit},
                    onSelectionChanged: (next) => setSheet(() {
                      amountUnit = next.first;
                      if (payMode &&
                          amountUnit == 'crypto' &&
                          paymentSource == 'wallet' &&
                          amount > balanceFor(provider)) {
                        paymentSource = 'external';
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
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
                            amountUnit == 'crypto' &&
                            paymentSource == 'wallet' &&
                            nextAmount > balanceFor(provider)) {
                          paymentSource = 'external';
                        }
                      });
                    },
                    decoration: InputDecoration(
                      labelText: amountUnit == 'crypto'
                          ? 'Amount ${provider.toUpperCase()}'
                          : 'Amount ${amountUnit.toUpperCase()}',
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
                  GlassButtonWidget.icon(
                    onPressed: submitting ? null : submit,
                    icon: submitting
                        ? const GlassProgressIndicator.circular(
                            size: 16,
                            strokeWidth: 2,
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
      builder: (dialogCtx) => GlassAlertDialog(
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
          builder: (_) => GlassAlertDialog(
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
      builder: (_) => GlassAlertDialog(
        title: Text('PGP Fingerprint'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdentityQrView(
              data: identityFingerprintQrPayload(_user.keyFingerprint),
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
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _scanFingerprintQR();
            },
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan to verify'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanFingerprintQR() async {
    if (_user.keyFingerprint.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => IdentityQrScannerScreen(
          expectedFingerprint: _user.keyFingerprint,
          expectedUsername: _user.username,
        ),
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
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: Text('@${_user.username}'),
        actions: [
          if (isAdmin && !_isOwnProfile)
            IconButton(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Admin actions',
              onPressed: () => _showAdminMenu(context),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: GlassProgressIndicator.circular())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
                16,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              children: [
                // ── Warning banners ──────────────────────────────────────────
                if (_user.isFlaggedScammer)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: cs.error.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: cs.error.withValues(alpha: 0.32),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: cs.error),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'This user has been flagged as a scammer. Exercise caution.',
                              style: TextStyle(
                                color: cs.error,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (_user.isBanned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: cs.onSurface.withValues(alpha: 0.18),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.block,
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'This account has been banned.',
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.65),
                              fontWeight: FontWeight.w500,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // ── Avatar + name hero ────────────────────────────────────────
                GlassCard(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                  child: Column(
                    children: [
                      // Avatar with glow
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: cs.primary.withValues(alpha: 0.30),
                              blurRadius: 24,
                              spreadRadius: -4,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: CircleAvatar(
                          radius: 52,
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
                                    fontSize: 38,
                                    fontWeight: FontWeight.w700,
                                    color: cs.onPrimaryContainer,
                                  ),
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Username + badges
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '@${_user.username}',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
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
                          if (_user.isPremium)
                            const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.workspace_premium,
                                size: 18,
                                color: Colors.amber,
                              ),
                            ),
                          if (_user.isBot)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: cs.secondaryContainer,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'BOT',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: cs.onSecondaryContainer,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      // Online status pill
                      const SizedBox(height: 8),
                      GlassContainer(
                        shape: LiquidRoundedSuperellipse(borderRadius: 999),
                        allowElevation: true,
                        glowIntensity: 0.06,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _user.isOnline
                                      ? const Color(0xFF34C759)
                                      : cs.onSurface.withValues(alpha: 0.35),
                                  boxShadow: _user.isOnline
                                      ? [
                                          BoxShadow(
                                            color: const Color(
                                              0xFF34C759,
                                            ).withValues(alpha: 0.60),
                                            blurRadius: 6,
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _user.isOnline ? 'Online' : 'Offline',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface.withValues(alpha: 0.75),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Bio
                      if (_user.bio != null && _user.bio!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          _user.bio!,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.65),
                            fontSize: 14,
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      // Pay button
                      if (!_isOwnProfile) ...[
                        const SizedBox(height: 18),
                        GlassButtonWidget.icon(
                          onPressed: _showPaymentSheet,
                          icon: const Icon(Icons.payments_outlined, size: 18),
                          label: const Text('Pay or request'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // ── Details card ──────────────────────────────────────────────
                GlassCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      if (_user.isPremium) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.amber.withValues(alpha: 0.16),
                                ),
                                child: const Icon(
                                  Icons.workspace_premium,
                                  color: Colors.amber,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Premium active',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                      ),
                                    ),
                                    if (_user.premiumUntil != null)
                                      Text(
                                        'Until ${_user.premiumUntil!.toLocal().toString().split('.').first}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: cs.onSurface.withValues(
                                            alpha: 0.55,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 66,
                          color: cs.onSurface.withValues(alpha: 0.10),
                        ),
                      ],
                      // PGP Fingerprint
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: cs.primary.withValues(alpha: 0.12),
                              ),
                              child: Icon(
                                Icons.key_outlined,
                                size: 18,
                                color: cs.primary,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'PGP Fingerprint',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    _user.shortFingerprint,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.55,
                                      ),
                                    ),
                                  ),
                                  if (KeyVerificationBadge.shouldShow(
                                    _keyTrustPin,
                                  )) ...[
                                    const SizedBox(height: 6),
                                    KeyVerificationBadge(pin: _keyTrustPin),
                                  ],
                                ],
                              ),
                            ),
                            if (_user.keyFingerprint.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.qr_code_rounded),
                                tooltip: 'Verify fingerprint',
                                onPressed: _showFingerprintQR,
                                color: cs.primary,
                              ),
                            if (_user.keyFingerprint.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.qr_code_scanner_rounded),
                                tooltip: 'Scan fingerprint QR',
                                onPressed: _scanFingerprintQR,
                                color: cs.primary,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Shared conversations ──────────────────────────────────────
                if (!_isOwnProfile) ...[
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 10),
                    child: Text(
                      'SHARED CHATS & CHANNELS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: FutureBuilder<List<Conversation>>(
                      future: _sharedConversationsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.all(20),
                            child: Center(
                              child: GlassProgressIndicator.circular(
                                size: 20,
                                strokeWidth: 2,
                              ),
                            ),
                          );
                        }
                        final convs = snapshot.data ?? const <Conversation>[];
                        if (convs.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.forum_outlined,
                                  color: cs.onSurface.withValues(alpha: 0.40),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  'No shared groups or channels',
                                  style: TextStyle(
                                    color: cs.onSurface.withValues(alpha: 0.55),
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return Column(
                          children: [
                            for (var i = 0; i < convs.take(8).length; i++) ...[
                              if (i > 0)
                                Divider(
                                  height: 1,
                                  thickness: 0.5,
                                  indent: 66,
                                  color: cs.onSurface.withValues(alpha: 0.10),
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: cs.primary.withValues(
                                          alpha: 0.12,
                                        ),
                                      ),
                                      child: Icon(
                                        convs[i].isChannel
                                            ? Icons.campaign_outlined
                                            : Icons.group_outlined,
                                        size: 18,
                                        color: cs.primary,
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            convs[i].displayName(''),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                          Text(
                                            convs[i].isChannel
                                                ? 'Channel'
                                                : 'Group',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: cs.onSurface.withValues(
                                                alpha: 0.50,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ],
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

class _ProfileMenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ProfileMenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
    return GlassListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tint.withValues(alpha: 0.12),
        ),
        child: Icon(icon, size: 18, color: tint),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: color,
        ),
      ),
      onTap: onTap,
    );
  }
}
