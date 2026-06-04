import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _invoices = const [];
  List<Map<String, dynamic>> _balances = const [];
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
      final balances = await api.getPaymentBalances();
      if (mounted) {
        setState(() {
          _status = s;
          _invoices = invoices.cast<Map<String, dynamic>>();
          _balances = balances.cast<Map<String, dynamic>>();
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
      backgroundColor: Colors.transparent,
      builder: (_) => _ProviderPickerSheet(
        plan: plan,
        providers: ((_status?['providers'] as List?) ?? []).cast<String>(),
        balances: _balances,
        pendingProviders: _pendingProviders,
        onPicked: (provider, source) async {
          Navigator.pop(context);
          await _startCheckout(plan: plan, provider: provider, source: source);
        },
      ),
    );
  }

  Set<String> get _pendingProviders => _invoices
      .where((invoice) => invoice['status'] == 'pending')
      .map((invoice) => invoice['provider'] as String)
      .toSet();

  Future<void> _startCheckout({
    required String plan,
    required String provider,
    required String source,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    try {
      final result = await api.createCheckout(
        plan: plan,
        provider: provider,
        source: source,
      );
      final invoice = result['invoice'] as Map<String, dynamic>;
      setState(() => _invoices = [invoice, ..._invoices]);
      if (source == 'wallet') {
        await auth.refreshCurrentUser();
        if (mounted) {
          await _loadStatus();
          messenger.showSnackBar(
            const SnackBar(content: Text('Premium paid from app wallet')),
          );
        }
        return;
      }
      final redirectURL = result['redirect_url'] as String?;
      if (provider == 'stripe' &&
          redirectURL != null &&
          redirectURL.isNotEmpty) {
        await launchUrl(
          Uri.parse(redirectURL),
          mode: LaunchMode.externalApplication,
        );
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

  void _showInvoiceWait(
    Map<String, dynamic> invoice, {
    required bool externalCheckout,
  }) {
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
      appBar: const GlassAppBar(title: Text('OpenChat Premium')),
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
                    GlassCard(
                      tint: theme.colorScheme.error.withValues(alpha: 0.10),
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.colorScheme.error.withValues(
                                alpha: 0.14,
                              ),
                            ),
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 16,
                              color: theme.colorScheme.error,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'This server has not configured any payment providers. '
                              'Ask the operator to enable Stripe, Bitcoin, or Monero.',
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
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
            .map(
              (item) =>
                  item['id'] == id ? {...item, 'status': 'cancelled'} : item,
            )
            .toList(growable: false);
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Payment cancelled')),
      );
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
    final scheme = Theme.of(context).colorScheme;
    final isPremium = user?.isPremium == true;
    final until = user?.premiumUntil as DateTime?;
    return GlassCard(
      tint: isPremium ? scheme.primary.withValues(alpha: 0.08) : null,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isPremium
                  ? Colors.amber.withValues(alpha: 0.18)
                  : scheme.onSurface.withValues(alpha: 0.08),
              boxShadow: isPremium
                  ? [
                      BoxShadow(
                        color: Colors.amber.withValues(alpha: 0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              isPremium
                  ? Icons.workspace_premium
                  : Icons.workspace_premium_outlined,
              size: 26,
              color: isPremium
                  ? Colors.amber
                  : scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPremium ? 'Premium active' : 'Free tier',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (isPremium && until != null)
                  Text(
                    'Expires ${until.toLocal().toString().split('.').first}',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                if (!isPremium)
                  Text(
                    'Upgrade to remove limits and unlock extras.',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatCrypto(double amount, String provider) {
  final decimals = provider == 'btc' ? 8 : 12;
  return '${amount.toStringAsFixed(decimals)} ${provider.toUpperCase()}';
}

double _balanceFor(List<Map<String, dynamic>> balances, String provider) {
  for (final balance in balances) {
    if (balance['provider'] == provider) {
      final available = balance['available'];
      if (available is num) return available.toDouble();
      if (available is String) return double.tryParse(available) ?? 0;
    }
  }
  return 0;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
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
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      tint: highlighted ? scheme.primary.withValues(alpha: 0.10) : null,
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        priceLabel,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: scheme.primary,
                        ),
                      ),
                      if (savings != null)
                        Text(
                          savings!,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.secondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 14,
                  color: scheme.onSurface.withValues(alpha: 0.40),
                ),
              ],
            ),
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
    ('1,000 custom emoji per pack', 'instead of 50'),
    ('100 custom emoji packs', 'instead of 5'),
    ('10 bots', 'instead of 1'),
    (
      'Channel-wide custom wallpapers',
      'set a WebP background visible to all subscribers',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          for (var i = 0; i < _items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.5,
                indent: 60,
                color: scheme.onSurface.withValues(alpha: 0.10),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary.withValues(alpha: 0.12),
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _items[i].$1,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _items[i].$2,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.55),
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
      ),
    );
  }
}

class _ProviderPickerSheet extends StatelessWidget {
  final String plan;
  final List<String> providers;
  final List<Map<String, dynamic>> balances;
  final Set<String> pendingProviders;
  final void Function(String provider, String source) onPicked;

  const _ProviderPickerSheet({
    required this.plan,
    required this.providers,
    required this.balances,
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
    final walletProviders = providers
        .where((provider) => provider == 'btc' || provider == 'xmr')
        .toList(growable: false);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: LiquidGlass(
          blur: 56,
          borderRadius: const BorderRadius.all(Radius.circular(28)),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pay for ${plan == 'year' ? 'yearly' : 'monthly'} premium',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              if (walletProviders.isNotEmpty) ...[
                Text(
                  'App wallet',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                GlassCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final (i, p) in walletProviders.indexed) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            thickness: 0.5,
                            indent: 66,
                            color: scheme.onSurface.withValues(alpha: 0.10),
                          ),
                        _ProviderTile(
                          icon: _icon(p),
                          title: '${p.toUpperCase()} balance',
                          subtitle: _formatCrypto(_balanceFor(balances, p), p),
                          onTap: () => onPicked(p, 'wallet'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                'External wallet or card',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final (i, p) in providers.indexed) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 66,
                          color: scheme.onSurface.withValues(alpha: 0.10),
                        ),
                      _ProviderTile(
                        icon: _icon(p),
                        title: _label(p),
                        subtitle: pendingProviders.contains(p)
                            ? 'A pending payment already exists'
                            : null,
                        trailing: pendingProviders.contains(p)
                            ? Icon(
                                Icons.hourglass_top,
                                size: 18,
                                color: scheme.onSurface.withValues(alpha: 0.45),
                              )
                            : null,
                        enabled: !pendingProviders.contains(p),
                        onTap: pendingProviders.contains(p)
                            ? null
                            : () => onPicked(p, 'external'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool enabled;
  final VoidCallback? onTap;

  const _ProviderTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.enabled = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled
        ? scheme.primary
        : scheme.onSurface.withValues(alpha: 0.35);
    return ClipRRect(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.12),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: enabled
                              ? null
                              : scheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                    ],
                  ),
                ),
                trailing ??
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: scheme.onSurface.withValues(alpha: 0.35),
                    ),
              ],
            ),
          ),
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
          Text(
            'Pending payments',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
          Text(
            'Payment history',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
    final detectedAmount = _asDouble(invoice['detected_amount']);
    final requestedAmount = _asDouble(invoice['crypto_amount']);
    final requiredConfirmations = provider == 'xmr'
        ? 20
        : provider == 'btc'
        ? 2
        : 0;
    final providerLabel = _providerLabel(provider);
    final statusText = status == 'pending' && requiredConfirmations > 0
        ? detected
              ? detectedAmount > 0 && requestedAmount > 0
                    ? '${_formatCrypto(detectedAmount, provider)} detected of ${_formatCrypto(requestedAmount, provider)}'
                    : '$confirmations / $requiredConfirmations confirmations'
              : 'Waiting for blockchain detection'
        : status;
    final date =
        ((invoice['paid_at'] ?? invoice['created_at']) as String?)
            ?.replaceFirst('T', ' ')
            .split('.')
            .first ??
        '';

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary.withValues(alpha: 0.12),
                    ),
                    child: Icon(
                      _providerIcon(provider),
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$providerLabel • ${plan == 'year' ? 'Yearly' : 'Monthly'}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '$statusText${date.isEmpty ? '' : ' • $date'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
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
      final updated = await context.read<ApiService>().getInvoice(
        _invoice['id'] as String,
      );
      if (!mounted) return;
      setState(() => _invoice = updated);
      if (updated['status'] == 'paid') widget.onPaid();
    } catch (_) {
      /* poll silently */
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _invoice['status'] as String;
    final provider = _invoice['provider'] as String;
    final address = _invoice['crypto_address'] as String?;
    final amount = _asDouble(_invoice['crypto_amount']);
    final detectedAmount = _asDouble(_invoice['detected_amount']);
    final confirmations = _invoice['confirmations'] as int? ?? 0;
    final requiredConfirmations = provider == 'xmr'
        ? 20
        : (provider == 'btc' ? 2 : 0);
    final detected = _invoice['detected_txid'] != null;

    return GlassAlertDialog(
      title: Text(status == 'paid' ? 'Payment confirmed' : 'Awaiting payment'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status == 'paid')
            const Text('Your premium subscription is now active.')
          else if (widget.externalCheckout)
            const Text(
              'Complete the payment in your browser. This dialog updates automatically.',
            )
          else if (address != null && amount > 0)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Send at least ${_formatCrypto(amount, provider)} to:'),
                const SizedBox(height: 8),
                SelectableText(
                  address,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (detectedAmount > 0)
                  Text('Detected: ${_formatCrypto(detectedAmount, provider)}'),
                Text(
                  detected
                      ? 'Confirmations: $confirmations / $requiredConfirmations'
                      : 'Waiting for blockchain detection',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ],
            )
          else
            Text(
              'Status: $status',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
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
