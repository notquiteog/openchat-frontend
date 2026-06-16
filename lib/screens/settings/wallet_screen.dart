import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/app_lock_state.dart';
import '../../widgets/deposit_progress_view.dart';
import '../../widgets/glass.dart';

/// Deposits still in flight: anything not yet confirmed and not expired.
/// These get a live-progress card instead of a static history row; once the
/// poller flips them to confirmed/expired they move into the history list.
List<Map<String, dynamic>> pendingDeposits(List<Map<String, dynamic>> all) {
  final out = all.where((dep) {
    final status = (dep['status'] ?? '').toString();
    return status != 'confirmed' && status != 'expired';
  }).toList();
  out.sort(
    (a, b) => (b['created_at'] ?? '').toString().compareTo(
      (a['created_at'] ?? '').toString(),
    ),
  );
  return out;
}

/// One pending deposit: provider header + live confirmation ring. Tapping
/// re-opens the address sheet so the user can copy the address again.
class PendingDepositCard extends StatelessWidget {
  final Map<String, dynamic> deposit;
  final VoidCallback? onTap;
  final VoidCallback? onConfirmed;

  /// Test seam forwarded to [DepositProgressView].
  @visibleForTesting
  final Stream<Map<String, dynamic>>? progressStream;

  const PendingDepositCard({
    super.key,
    required this.deposit,
    this.onTap,
    this.onConfirmed,
    this.progressStream,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = (deposit['provider'] ?? '').toString();
    final isSub = (deposit['purpose'] ?? 'topup') == 'channel_sub';
    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isSub
                      ? Icons.workspace_premium_outlined
                      : Icons.arrow_downward,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isSub
                        ? 'Channel subscription ${provider.toUpperCase()}'
                        : 'Deposit ${provider.toUpperCase()}',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Icons.qr_code_2,
                  size: 18,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DepositProgressView(
              depositId: (deposit['id'] ?? '').toString(),
              initialConfirmations:
                  (deposit['confirmations'] as num?)?.toInt() ?? 0,
              requiredConfirmations:
                  (deposit['required_confirmations'] as num?)?.toInt() ?? 0,
              initialStatus: deposit['status']?.toString() ?? 'nothing_sent',
              onConfirmed: onConfirmed,
              progressStream: progressStream,
            ),
          ],
        ),
      ),
    );
  }
}

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  bool _loading = true;
  String? _error;
  List<String> _providers = const ['btc', 'xmr'];
  List<Map<String, dynamic>> _balances = const [];
  List<Map<String, dynamic>> _deposits = const [];
  List<Map<String, dynamic>> _transfers = const [];
  List<Map<String, dynamic>> _withdrawals = const [];
  double _feeRate = 0.03;
  _WalletCategory _historyFilter = _WalletCategory.all;

  // Sentinel "deleted user" (backend migration 002): a counterparty who wiped
  // their account. Their side of a transaction is repointed here so this user's
  // own history survives.
  static const String _deletedUserId = '00000000-0000-0000-0000-0000000000de';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<ApiService>();
      final status = await api.getBillingStatus();
      final providers = ((status['providers'] as List?) ?? const [])
          .whereType<String>()
          .where((p) => p == 'btc' || p == 'xmr')
          .toList();
      final balances = await api.getPaymentBalances();
      final deposits = await api.listPaymentDeposits();
      final transfers = await api.listPaymentTransfers();
      final withdrawals = await api.listPaymentWithdrawals();
      if (!mounted) return;
      setState(() {
        _providers = providers.isEmpty ? const ['btc', 'xmr'] : providers;
        _balances = balances.cast<Map<String, dynamic>>();
        _deposits = deposits.cast<Map<String, dynamic>>();
        _transfers = transfers.cast<Map<String, dynamic>>();
        _withdrawals = withdrawals.cast<Map<String, dynamic>>();
        _feeRate = (status['withdrawal_fee_rate'] as num?)?.toDouble() ?? 0.03;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  double _balanceFor(String provider) {
    for (final balance in _balances) {
      if (balance['provider'] == provider) {
        return _asDouble(balance['available']);
      }
    }
    return 0;
  }

  Future<void> _createDeposit(String provider) async {
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => GlassAlertDialog(
          title: Text('Deposit ${provider.toUpperCase()}'),
          content: Text(
            'A fresh address will be generated for this deposit. Send any amount to it and OpenChat will detect the received funds automatically after confirmation.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final dep = await context.read<ApiService>().createPaymentDeposit(
        provider: provider,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      _showDepositAddress(dep);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deposit failed: $e')));
    }
  }

  void _showDepositAddress(Map<String, dynamic> dep) {
    final address = dep['crypto_address'] as String? ?? '';
    final depositId = (dep['id'] ?? '').toString();
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => GlassAlertDialog(
        title: Text('Send ${dep['provider'].toString().toUpperCase()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(address),
            if (depositId.isNotEmpty) ...[
              const SizedBox(height: 14),
              DepositProgressView(
                depositId: depositId,
                initialConfirmations:
                    (dep['confirmations'] as num?)?.toInt() ?? 0,
                requiredConfirmations:
                    (dep['required_confirmations'] as num?)?.toInt() ?? 0,
                initialStatus: dep['status']?.toString() ?? 'nothing_sent',
                onConfirmed: _load,
              ),
            ],
          ],
        ),
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

  Future<void> _withdraw(String provider) async {
    final addressCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final available = _balanceFor(provider);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => StatefulBuilder(
          builder: (dialogCtx, setDialog) {
            final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
            final net = amount * (1 - _feeRate);
            final fee = amount - net;
            return GlassAlertDialog(
              title: Text('Withdraw ${provider.toUpperCase()}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: addressCtrl,
                    decoration: const InputDecoration(labelText: 'Address'),
                    onChanged: (_) => setDialog(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Amount ${provider.toUpperCase()}',
                      helperText:
                          'Available ${_formatCrypto(available, provider)}',
                    ),
                    onChanged: (_) => setDialog(() {}),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Fee ${_formatCrypto(fee > 0 ? fee : 0, provider)} - Net ${_formatCrypto(net > 0 ? net : 0, provider)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed:
                      amount > 0 &&
                          amount <= available &&
                          addressCtrl.text.trim().isNotEmpty
                      ? () => Navigator.pop(dialogCtx, true)
                      : null,
                  child: const Text('Withdraw'),
                ),
              ],
            );
          },
        ),
      );
      if (confirmed != true || !mounted) return;
      await context.read<ApiService>().withdrawPaymentFunds(
        provider: provider,
        address: addressCtrl.text.trim(),
        amount: double.parse(amountCtrl.text.trim()),
      );
      if (mounted) await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Withdrawal failed: $e')));
    } finally {
      addressCtrl.dispose();
      amountCtrl.dispose();
    }
  }

  List<_WalletHistoryItem> _historyItems(String? currentUserID) {
    final out = <_WalletHistoryItem>[];
    for (final dep in _deposits) {
      final provider = dep['provider'] as String? ?? '';
      final purpose = dep['purpose'] as String? ?? 'topup';
      final status = (dep['status'] ?? '').toString();
      // Actively pending deposits live in the "Pending deposits" section with
      // a live progress ring — history keeps the settled ones.
      if (status != 'confirmed' && status != 'expired') continue;
      // A peer / subscription deposit also produces a peer transfer once
      // confirmed; skip it there to avoid double-counting (it shows as the
      // transfer).
      if (purpose != 'topup' && dep['peer_transfer_id'] != null) continue;
      final isSub = purpose == 'channel_sub';
      final amount = _asDouble(
        dep['detected_amount'] ?? dep['expected_amount'],
      );
      out.add(
        _WalletHistoryItem(
          date: _parseDate(dep['updated_at'] ?? dep['created_at']),
          icon: isSub ? Icons.workspace_premium_outlined : Icons.arrow_downward,
          title: isSub
              ? 'Channel subscription ${provider.toUpperCase()}'
              : 'Deposit ${provider.toUpperCase()}',
          amount: amount > 0 ? '+${_formatCrypto(amount, provider)}' : null,
          subtitle: (dep['status'] as String? ?? '').replaceAll('_', ' '),
          category: isSub
              ? _WalletCategory.subscriptions
              : _WalletCategory.deposits,
        ),
      );
    }
    for (final withdrawal in _withdrawals) {
      final provider = withdrawal['provider'] as String? ?? '';
      out.add(
        _WalletHistoryItem(
          date: _parseDate(
            withdrawal['updated_at'] ?? withdrawal['created_at'],
          ),
          icon: Icons.arrow_upward,
          title: 'Withdrawal ${provider.toUpperCase()}',
          amount:
              '-${_formatCrypto(_asDouble(withdrawal['amount']), provider)}',
          subtitle:
              '${(withdrawal['status'] as String? ?? '').replaceAll('_', ' ')} - fee ${_formatCrypto(_asDouble(withdrawal['fee_amount']), provider)}',
          category: _WalletCategory.withdrawals,
        ),
      );
    }
    for (final transfer in _transfers) {
      final provider = transfer['provider'] as String? ?? '';
      final purpose = transfer['purpose'] as String? ?? 'peer';
      final incoming = transfer['to_user_id'] == currentUserID;
      final isSub = purpose == 'channel_sub';
      final counterparty =
          (incoming ? transfer['from_user_id'] : transfer['to_user_id'])
              as String?;
      final note = transfer['note'] as String? ?? '';
      final parts = <String>[
        if (counterparty == _deletedUserId)
          incoming ? 'from deleted user' : 'to deleted user',
        if (note.isNotEmpty) note,
      ];
      out.add(
        _WalletHistoryItem(
          date: _parseDate(transfer['created_at']),
          icon: isSub
              ? Icons.workspace_premium_outlined
              : (incoming ? Icons.call_received : Icons.call_made),
          title: isSub
              ? (incoming
                    ? 'Subscriber payment ${provider.toUpperCase()}'
                    : 'Channel subscription ${provider.toUpperCase()}')
              : (incoming
                    ? 'Received ${provider.toUpperCase()}'
                    : 'Sent ${provider.toUpperCase()}'),
          amount:
              '${incoming ? '+' : '-'}${_formatCrypto(_asDouble(transfer['amount']), provider)}',
          subtitle: parts.join(' · '),
          category: isSub
              ? _WalletCategory.subscriptions
              : (incoming ? _WalletCategory.received : _WalletCategory.sent),
        ),
      );
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final currentUserID = context.watch<AuthProvider>().currentUser?.id;
    final theme = Theme.of(context);
    return ValueListenableBuilder<VaultMode>(
      valueListenable: vaultModeListenable,
      builder: (context, vaultMode, _) =>
          _buildWallet(context, theme, currentUserID, vaultMode),
    );
  }

  Widget _buildWallet(
    BuildContext context,
    ThemeData theme,
    String? currentUserID,
    VaultMode vaultMode,
  ) {
    // Decoy (duress-PIN) sessions render a genuinely unused wallet: zero
    // balances, no pending deposits, no history, actions disabled. The real
    // data stays in state but is never read — and crucially this is neither
    // an error nor a visibly censored view.
    final isDecoy = vaultMode == VaultMode.decoy;
    final allItems = isDecoy
        ? const <_WalletHistoryItem>[]
        : _historyItems(currentUserID);
    final filteredItems = _historyFilter == _WalletCategory.all
        ? allItems
        : allItems.where((it) => it.category == _historyFilter).toList();
    final pending = isDecoy
        ? const <Map<String, dynamic>>[]
        : pendingDeposits(_deposits);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Wallet')),
      body: _loading && !isDecoy
          ? const Center(child: GlassProgressIndicator.circular())
          : _error != null && !isDecoy
          ? Center(child: Text('Failed to load wallet: $_error'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
                  16,
                  MediaQuery.paddingOf(context).bottom + 32,
                ),
                children: [
                  for (final provider in _providers) ...[
                    GlassCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.12,
                                  ),
                                ),
                                child: Icon(
                                  provider == 'btc'
                                      ? Icons.currency_bitcoin
                                      : Icons.lock_outline,
                                  size: 18,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                provider.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _formatCrypto(
                              isDecoy ? 0 : _balanceFor(provider),
                              provider,
                            ),
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              GlassButtonWidget.icon(
                                onPressed: isDecoy
                                    ? null
                                    : () => _createDeposit(provider),
                                icon: const Icon(
                                  Icons.arrow_downward,
                                  size: 16,
                                ),
                                label: const Text('Deposit'),
                              ),
                              const SizedBox(width: 8),
                              GlassButtonWidget.icon(
                                onPressed: !isDecoy && _balanceFor(provider) > 0
                                    ? () => _withdraw(provider)
                                    : null,
                                icon: const Icon(Icons.arrow_upward, size: 16),
                                label: const Text('Withdraw'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (pending.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 10),
                      child: Text(
                        'PENDING DEPOSITS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    for (final dep in pending) ...[
                      PendingDepositCard(
                        deposit: dep,
                        onTap: () => _showDepositAddress(dep),
                        onConfirmed: _load,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 10),
                    child: Text(
                      'TRANSACTION HISTORY',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  // Category filter — keeps deposits, peer payments, channel
                  // subscriptions and withdrawals visually separate.
                  if (allItems.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final cat in _WalletCategory.values)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: lg.GlassChip(
                                  label: cat.label,
                                  selected: _historyFilter == cat,
                                  onTap: () =>
                                      setState(() => _historyFilter = cat),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (allItems.isEmpty)
                    GlassCard(
                      padding: const EdgeInsets.all(18),
                      child: Row(
                        children: [
                          Icon(
                            Icons.receipt_long_outlined,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.40,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'No transactions yet',
                            style: TextStyle(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (filteredItems.isEmpty)
                    GlassCard(
                      padding: const EdgeInsets.all(18),
                      child: Row(
                        children: [
                          Icon(
                            Icons.filter_list_off,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.40,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'No ${_historyFilter.label.toLowerCase()} transactions',
                            style: TextStyle(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    GlassCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < filteredItems.length; i++) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                thickness: 0.5,
                                indent: 60,
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.10,
                                ),
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
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.10),
                                    ),
                                    child: Icon(
                                      filteredItems[i].icon,
                                      size: 18,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          filteredItems[i].title,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                        Text(
                                          filteredItems[i].subtitle.isEmpty
                                              ? filteredItems[i].dateLabel
                                              : '${filteredItems[i].subtitle} — ${filteredItems[i].dateLabel}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.55),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (filteredItems[i].amount != null)
                                    Text(
                                      filteredItems[i].amount!,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

enum _WalletCategory {
  all('All'),
  deposits('Deposits'),
  sent('Sent'),
  received('Received'),
  subscriptions('Subs'),
  withdrawals('Withdrawals');

  const _WalletCategory(this.label);
  final String label;
}

class _WalletHistoryItem {
  final DateTime date;
  final IconData icon;
  final String title;
  final String? amount;
  final String subtitle;
  final _WalletCategory category;

  const _WalletHistoryItem({
    required this.date,
    required this.icon,
    required this.title,
    required this.amount,
    required this.subtitle,
    required this.category,
  });

  String get dateLabel => date.toLocal().toString().split('.').first;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

DateTime _parseDate(Object? value) {
  if (value is String) {
    return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

String _formatCrypto(double amount, String provider) {
  final decimals = provider == 'btc' ? 8 : 12;
  return '${amount.toStringAsFixed(decimals)} ${provider.toUpperCase()}';
}
