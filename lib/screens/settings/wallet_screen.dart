import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

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
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => GlassAlertDialog(
        title: Text('Send ${dep['provider'].toString().toUpperCase()}'),
        content: SelectableText(address),
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
      final amount = _asDouble(
        dep['detected_amount'] ?? dep['expected_amount'],
      );
      out.add(
        _WalletHistoryItem(
          date: _parseDate(dep['updated_at'] ?? dep['created_at']),
          icon: Icons.arrow_downward,
          title: 'Deposit ${provider.toUpperCase()}',
          amount: amount > 0 ? '+${_formatCrypto(amount, provider)}' : null,
          subtitle: (dep['status'] as String? ?? '').replaceAll('_', ' '),
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
        ),
      );
    }
    for (final transfer in _transfers) {
      final provider = transfer['provider'] as String? ?? '';
      final incoming = transfer['to_user_id'] == currentUserID;
      out.add(
        _WalletHistoryItem(
          date: _parseDate(transfer['created_at']),
          icon: incoming ? Icons.call_received : Icons.call_made,
          title: incoming
              ? 'Received ${provider.toUpperCase()}'
              : 'Sent ${provider.toUpperCase()}',
          amount:
              '${incoming ? '+' : '-'}${_formatCrypto(_asDouble(transfer['amount']), provider)}',
          subtitle: transfer['note'] as String? ?? '',
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
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Wallet')),
      body: _loading
          ? const Center(child: GlassProgressIndicator.circular())
          : _error != null
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
                            _formatCrypto(_balanceFor(provider), provider),
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
                                onPressed: () => _createDeposit(provider),
                                icon: const Icon(
                                  Icons.arrow_downward,
                                  size: 16,
                                ),
                                label: const Text('Deposit'),
                              ),
                              const SizedBox(width: 8),
                              GlassButtonWidget.icon(
                                onPressed: _balanceFor(provider) > 0
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
                  if (_historyItems(currentUserID).isEmpty)
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
                  else
                    GlassCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (
                            var i = 0;
                            i < _historyItems(currentUserID).length;
                            i++
                          ) ...[
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
                                      _historyItems(currentUserID)[i].icon,
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
                                          _historyItems(currentUserID)[i].title,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                        Text(
                                          _historyItems(
                                                currentUserID,
                                              )[i].subtitle.isEmpty
                                              ? _historyItems(
                                                  currentUserID,
                                                )[i].dateLabel
                                              : '${_historyItems(currentUserID)[i].subtitle} — ${_historyItems(currentUserID)[i].dateLabel}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.55),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_historyItems(currentUserID)[i].amount !=
                                      null)
                                    Text(
                                      _historyItems(currentUserID)[i].amount!,
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

class _WalletHistoryItem {
  final DateTime date;
  final IconData icon;
  final String title;
  final String? amount;
  final String subtitle;

  const _WalletHistoryItem({
    required this.date,
    required this.icon,
    required this.title,
    required this.amount,
    required this.subtitle,
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
