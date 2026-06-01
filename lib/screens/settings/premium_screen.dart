import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _invoices = const [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final api = context.read<ApiService>();
      final s = await api.getBillingStatus();
      final invoices = await api.listInvoices();
      if (mounted) {
        setState(() {
          _status = s;
          _invoices = invoices.cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _openCheckout(String plan) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ProviderPickerSheet(
        plan: plan,
        providers: ((_status?['providers'] as List?) ?? []).cast<String>(),
        pendingProviders: _pendingProviders,
        onPicked: (provider) async {
          Navigator.pop(context);
          await _startCheckout(plan: plan, provider: provider);
        },
      ),
    );
  }

  Set<String> get _pendingProviders => _invoices
      .where((invoice) => invoice['status'] == 'pending')
      .map((invoice) => invoice['provider'] as String)
      .toSet();

  Future<void> _startCheckout(
      {required String plan, required String provider}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await context.read<ApiService>().createCheckout(
            plan: plan,
            provider: provider,
          );
      final invoice = result['invoice'] as Map<String, dynamic>;
      setState(() => _invoices = [invoice, ..._invoices]);
      final redirectURL = result['redirect_url'] as String?;
      if (provider == 'stripe' &&
          redirectURL != null &&
          redirectURL.isNotEmpty) {
        await launchUrl(Uri.parse(redirectURL),
            mode: LaunchMode.externalApplication);
        if (mounted) {
          _showInvoiceWait(invoice, externalCheckout: true);
        }
      } else {
        if (mounted) _showInvoiceWait(invoice, externalCheckout: false);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Checkout failed: $e')));
      await _loadStatus();
    }
  }

  void _showInvoiceWait(Map<String, dynamic> invoice,
      {required bool externalCheckout}) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InvoiceWaitDialog(
        initial: invoice,
        externalCheckout: externalCheckout,
        onPaid: () async {
          Navigator.pop(context);
          await context.read<AuthProvider>().refreshCurrentUser();
          if (mounted) await _loadStatus();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('OpenChat Premium')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(child: Text('Failed to load: $_loadError'))
              : RefreshIndicator(
                  onRefresh: _loadStatus,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _PremiumStatusCard(user: user),
                      _PaymentSections(
                        invoices: _invoices,
                        onCancel: _cancelInvoice,
                        onOpen: (invoice) => _showInvoiceWait(
                          invoice,
                          externalCheckout: invoice['provider'] == 'stripe',
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('Choose a plan', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      _PlanCard(
                        plan: 'year',
                        title: 'Yearly',
                        priceLabel: '€10 / year',
                        savings: 'Save 58% vs monthly',
                        highlighted: true,
                        onTap: () => _openCheckout('year'),
                      ),
                      const SizedBox(height: 8),
                      _PlanCard(
                        plan: 'month',
                        title: 'Monthly',
                        priceLabel: '€2 / month',
                        onTap: () => _openCheckout('month'),
                      ),
                      const SizedBox(height: 24),
                      Text('What you get', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const _PremiumFeatures(),
                      if (((_status?['providers'] as List?) ?? []).isEmpty) ...[
                        const SizedBox(height: 24),
                        Card(
                          color: theme.colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'This server has not configured any payment providers. '
                              'Ask the operator to enable Stripe, Bitcoin, or Monero.',
                              style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Future<void> _cancelInvoice(Map<String, dynamic> invoice) async {
    final id = invoice['id'] as String;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<ApiService>().cancelInvoice(id);
      setState(() {
        _invoices = _invoices
            .map((item) =>
                item['id'] == id ? {...item, 'status': 'cancelled'} : item)
            .toList(growable: false);
      });
      messenger
          .showSnackBar(const SnackBar(content: Text('Payment cancelled')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Cancel failed: $e')));
    }
  }
}

class _PremiumStatusCard extends StatelessWidget {
  final dynamic user;
  const _PremiumStatusCard({required this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPremium = user?.isPremium == true;
    final until = user?.premiumUntil as DateTime?;
    return Card(
      color: isPremium ? theme.colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              isPremium
                  ? Icons.workspace_premium
                  : Icons.workspace_premium_outlined,
              size: 32,
              color: isPremium ? theme.colorScheme.primary : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isPremium ? 'Premium active' : 'Free tier',
                    style: theme.textTheme.titleMedium,
                  ),
                  if (isPremium && until != null)
                    Text(
                        'Renews / expires ${until.toLocal().toString().split('.').first}'),
                  if (!isPremium)
                    const Text('Upgrade to remove limits and unlock extras.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String plan;
  final String title;
  final String priceLabel;
  final String? savings;
  final bool highlighted;
  final VoidCallback onTap;

  const _PlanCard({
    required this.plan,
    required this.title,
    required this.priceLabel,
    this.savings,
    this.highlighted = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: highlighted ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: highlighted
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    Text(priceLabel,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        )),
                    if (savings != null)
                      Text(savings!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.secondary,
                          )),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _PremiumFeatures extends StatelessWidget {
  const _PremiumFeatures();

  static const _items = [
    ('1,000 stickers per pack', 'instead of 50'),
    ('100 sticker packs', 'instead of 5'),
    ('10 bots', 'instead of 1'),
    (
      'Channel-wide custom wallpapers',
      'set a WebP background visible to all subscribers'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        children: [
          for (final (title, sub) in _items)
            ListTile(
              leading:
                  Icon(Icons.check_circle, color: theme.colorScheme.primary),
              title: Text(title),
              subtitle: Text(sub),
              dense: true,
            ),
        ],
      ),
    );
  }
}

class _ProviderPickerSheet extends StatelessWidget {
  final String plan;
  final List<String> providers;
  final Set<String> pendingProviders;
  final void Function(String provider) onPicked;

  const _ProviderPickerSheet({
    required this.plan,
    required this.providers,
    required this.pendingProviders,
    required this.onPicked,
  });

  String _label(String p) {
    switch (p) {
      case 'stripe':
        return 'Card (Stripe)';
      case 'btc':
        return 'Bitcoin';
      case 'xmr':
        return 'Monero';
      default:
        return p;
    }
  }

  IconData _icon(String p) {
    switch (p) {
      case 'stripe':
        return Icons.credit_card;
      case 'btc':
        return Icons.currency_bitcoin;
      case 'xmr':
        return Icons.lock_outline;
      default:
        return Icons.payment;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pay for ${plan == 'year' ? 'yearly' : 'monthly'} premium',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final p in providers)
              ListTile(
                leading: Icon(_icon(p)),
                title: Text(_label(p)),
                subtitle: pendingProviders.contains(p)
                    ? const Text('A pending payment already exists')
                    : null,
                trailing: pendingProviders.contains(p)
                    ? const Icon(Icons.hourglass_top)
                    : const Icon(Icons.chevron_right),
                enabled: !pendingProviders.contains(p),
                onTap: pendingProviders.contains(p) ? null : () => onPicked(p),
              ),
          ],
        ),
      ),
    );
  }
}

class _PaymentSections extends StatelessWidget {
  final List<Map<String, dynamic>> invoices;
  final void Function(Map<String, dynamic> invoice) onCancel;
  final void Function(Map<String, dynamic> invoice) onOpen;

  const _PaymentSections({
    required this.invoices,
    required this.onCancel,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final pending = invoices
        .where((invoice) => invoice['status'] == 'pending')
        .toList(growable: false);
    final paid = invoices
        .where((invoice) => invoice['status'] == 'paid')
        .toList(growable: false);
    if (pending.isEmpty && paid.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pending.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Pending payments',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final invoice in pending)
            _InvoiceTile(
              invoice: invoice,
              onTap: () => onOpen(invoice),
              trailing: TextButton(
                onPressed: () => onCancel(invoice),
                child: const Text('Cancel'),
              ),
            ),
        ],
        if (paid.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Payment history',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final invoice in paid) _InvoiceTile(invoice: invoice),
        ],
      ],
    );
  }
}

class _InvoiceTile extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _InvoiceTile({required this.invoice, this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final provider = invoice['provider'] as String;
    final status = invoice['status'] as String;
    final plan = invoice['plan'] as String;
    final confirmations = invoice['confirmations'] as int? ?? 0;
    final detected = invoice['detected_txid'] != null;
    final requiredConfirmations = provider == 'xmr'
        ? 20
        : provider == 'btc'
            ? 2
            : 0;
    final providerLabel = _providerLabel(provider);
    final statusText = status == 'pending' && requiredConfirmations > 0
        ? detected
            ? '$confirmations / $requiredConfirmations confirmations'
            : 'Waiting for blockchain detection'
        : status;
    final date = ((invoice['paid_at'] ?? invoice['created_at']) as String?)
            ?.replaceFirst('T', ' ')
            .split('.')
            .first ??
        '';

    return Card(
      child: ListTile(
        leading: Icon(_providerIcon(provider)),
        title:
            Text('$providerLabel • ${plan == 'year' ? 'Yearly' : 'Monthly'}'),
        subtitle: Text('$statusText${date.isEmpty ? '' : ' • $date'}'),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }

  static String _providerLabel(String provider) => switch (provider) {
        'stripe' => 'Card',
        'btc' => 'Bitcoin',
        'xmr' => 'Monero',
        _ => provider,
      };

  static IconData _providerIcon(String provider) => switch (provider) {
        'stripe' => Icons.credit_card,
        'btc' => Icons.currency_bitcoin,
        'xmr' => Icons.lock_outline,
        _ => Icons.payment,
      };
}

class _InvoiceWaitDialog extends StatefulWidget {
  final Map<String, dynamic> initial;
  final bool externalCheckout;
  final VoidCallback onPaid;

  const _InvoiceWaitDialog({
    required this.initial,
    required this.externalCheckout,
    required this.onPaid,
  });

  @override
  State<_InvoiceWaitDialog> createState() => _InvoiceWaitDialogState();
}

class _InvoiceWaitDialogState extends State<_InvoiceWaitDialog> {
  late Map<String, dynamic> _invoice;
  Timer? _poller;

  @override
  void initState() {
    super.initState();
    _invoice = widget.initial;
    _poller = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final updated =
          await context.read<ApiService>().getInvoice(_invoice['id'] as String);
      if (!mounted) return;
      setState(() => _invoice = updated);
      if (updated['status'] == 'paid') widget.onPaid();
    } catch (_) {/* poll silently */}
  }

  @override
  Widget build(BuildContext context) {
    final status = _invoice['status'] as String;
    final provider = _invoice['provider'] as String;
    final address = _invoice['crypto_address'] as String?;
    final amount = _invoice['crypto_amount'];
    final asset = provider == 'btc' ? 'BTC' : (provider == 'xmr' ? 'XMR' : '');
    final confirmations = _invoice['confirmations'] as int? ?? 0;
    final requiredConfirmations =
        provider == 'xmr' ? 20 : (provider == 'btc' ? 2 : 0);
    final detected = _invoice['detected_txid'] != null;

    return AlertDialog(
      title: Text(status == 'paid' ? 'Payment confirmed' : 'Awaiting payment'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status == 'paid')
            const Text('Your premium subscription is now active.')
          else if (widget.externalCheckout)
            const Text(
                'Complete the payment in your browser. This dialog updates automatically.')
          else if (address != null && amount != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Send exactly $amount $asset to:'),
                const SizedBox(height: 8),
                SelectableText(address,
                    style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy address'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: address));
                  },
                ),
              ],
            ),
          const SizedBox(height: 12),
          if (requiredConfirmations > 0 && status == 'pending')
            Text(
              detected
                  ? 'Confirmations: $confirmations / $requiredConfirmations'
                  : 'Waiting for blockchain detection',
              style: const TextStyle(fontStyle: FontStyle.italic),
            )
          else
            Text('Status: $status',
                style: const TextStyle(fontStyle: FontStyle.italic)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
