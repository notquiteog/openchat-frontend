import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../crypto/pgp_service.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

class BotManagementScreen extends StatefulWidget {
  const BotManagementScreen({super.key});

  @override
  State<BotManagementScreen> createState() => _BotManagementScreenState();
}

class _BotManagementScreenState extends State<BotManagementScreen> {
  List<Map<String, dynamic>> _bots = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBots();
  }

  Future<void> _loadBots() async {
    setState(() => _loading = true);
    try {
      final raw = await context.read<ApiService>().listBots();
      if (mounted) {
        setState(() {
          _bots = raw.cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _createBot() {
    showDialog<void>(
      context: context,
      builder: (ctx) => _CreateBotDialog(
        onCreated: (botData, privateKey) {
          _loadBots();
          _showCredentials(botData, privateKey);
        },
      ),
    );
  }

  void _showCredentials(Map<String, dynamic> botData, String privateKey) {
    final token = botData['api_token'] as String? ?? '';
    final username = botData['username'] as String? ?? '';
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Bot Created'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Save these credentials — the private key will never be shown again.',
                style: TextStyle(
                    color: Colors.orange, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              _CredentialField(label: 'Username', value: '@$username'),
              const SizedBox(height: 12),
              _CredentialField(
                  label: 'API Token', value: token, monospace: true),
              const SizedBox(height: 12),
              _CredentialField(
                label: 'Private Key (for bot SDK)',
                value: privateKey,
                monospace: true,
                maxLines: 6,
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(
                text: 'Token: $token\n\nPrivate Key:\n$privateKey',
              ));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Credentials copied to clipboard')),
              );
            },
            child: const Text('Copy All'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _openBot(Map<String, dynamic> bot) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _BotDetailScreen(bot: bot)),
    ).then((_) => _loadBots());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('My Bots'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create bot',
            onPressed: _createBot,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: GlassProgressIndicator.circular())
          : _bots.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.smart_toy_outlined,
                          size: 72,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.35)),
                      const SizedBox(height: 16),
                      Text('No bots yet',
                          style: TextStyle(
                            fontSize: 16,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.55),
                          )),
                      const SizedBox(height: 8),
                      Text(
                        'Create a bot to automate messages\nusing the OpenChat Bot API',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.45),
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 16),
                      GlassButtonWidget.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Create a bot'),
                        onPressed: _createBot,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  itemCount: _bots.length,
                  itemBuilder: (context, i) {
                    final bot = _bots[i];
                    final username = bot['username'] as String? ?? '';
                    final avatarUrl = bot['avatar_url'] as String?;
                    final description =
                        (bot['bio'] ?? bot['description']) as String?;
                    final scheme = Theme.of(context).colorScheme;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GlassCard(
                        padding: EdgeInsets.zero,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => _openBot(bot),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 22,
                                      backgroundImage: avatarUrl != null
                                          ? CachedNetworkImageProvider(
                                              ApiConfig.resolveMedia(avatarUrl))
                                          : null,
                                      child: avatarUrl == null
                                          ? Text(
                                              username.isNotEmpty
                                                  ? username[0].toUpperCase()
                                                  : 'B',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600),
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text('@$username',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600)),
                                          Text(
                                            description != null &&
                                                    description.isNotEmpty
                                                ? description
                                                : 'No description',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: scheme.onSurface
                                                  .withValues(alpha: 0.55),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_right,
                                        size: 18,
                                        color: scheme.onSurface
                                            .withValues(alpha: 0.35)),
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

class _CreateBotDialog extends StatefulWidget {
  final void Function(Map<String, dynamic> botData, String privateKey)
      onCreated;
  const _CreateBotDialog({required this.onCreated});

  @override
  State<_CreateBotDialog> createState() => _CreateBotDialogState();
}

class _CreateBotDialogState extends State<_CreateBotDialog> {
  final _usernameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _creating = false;
  String? _usernameError;
  final _picker = ImagePicker();
  String? _avatarUrl;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    try {
      final api = context.read<ApiService>();
      final bytes = await picked.readAsBytes();
      final url =
          await api.uploadAvatar(fileBytes: bytes, filename: picked.name);
      if (mounted) setState(() => _avatarUrl = url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Avatar upload failed: $e')),
        );
      }
    }
  }

  Future<void> _submit() async {
    final username = _usernameCtrl.text.trim().toLowerCase();
    if (username.isEmpty) {
      setState(() => _usernameError = 'Username is required');
      return;
    }
    if (!username.contains('bot')) {
      setState(() => _usernameError = 'Username must contain "bot"');
      return;
    }
    setState(() {
      _usernameError = null;
      _creating = true;
    });

    final api = context.read<ApiService>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final desc = _descCtrl.text.trim();
    final avatarUrl = _avatarUrl;

    try {
      final keyPair = await PgpService.generateKeyPair(username: username);

      final botData = await api.createBot(
        username: username,
        publicKey: keyPair.publicKeyArmored,
        description: desc.isEmpty ? null : desc,
        avatarUrl: avatarUrl,
      );

      if (mounted) {
        navigator.pop();
        widget.onCreated(botData, keyPair.privateKeyArmored);
      }
    } catch (e) {
      if (mounted) setState(() => _creating = false);
      messenger
          .showSnackBar(SnackBar(content: Text('Failed to create bot: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassAlertDialog(
      title: const Text('Create Bot'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _creating ? null : _pickAvatar,
              child: CircleAvatar(
                radius: 36,
                backgroundImage: _avatarUrl != null
                    ? CachedNetworkImageProvider(
                        ApiConfig.resolveMedia(_avatarUrl!))
                    : null,
                child: _avatarUrl == null
                    ? const Icon(Icons.add_a_photo, size: 28)
                    : null,
              ),
            ),
            const SizedBox(height: 4),
            const Text('Tap to set avatar',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameCtrl,
              decoration: InputDecoration(
                labelText: 'Username (must contain "bot")',
                prefixText: '@',
                errorText: _usernameError,
                hintText: 'mybot',
              ),
              onChanged: (_) {
                if (_usernameError != null) {
                  setState(() => _usernameError = null);
                }
              },
              enabled: !_creating,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descCtrl,
              decoration:
                  const InputDecoration(labelText: 'Description (optional)'),
              maxLines: 2,
              enabled: !_creating,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _creating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _creating ? null : _submit,
          child: _creating
              ? const GlassProgressIndicator.circular(size: 18, strokeWidth: 2, color: Colors.white)
              : const Text('Create'),
        ),
      ],
    );
  }
}

class _BotDetailScreen extends StatefulWidget {
  final Map<String, dynamic> bot;
  const _BotDetailScreen({required this.bot});

  @override
  State<_BotDetailScreen> createState() => _BotDetailScreenState();
}

class _BotDetailScreenState extends State<_BotDetailScreen> {
  late Map<String, dynamic> _bot;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _bot = widget.bot;
  }

  String get _username => _bot['username'] as String? ?? '';
  String? get _avatarUrl => _bot['avatar_url'] as String?;
  String? get _description => (_bot['bio'] ?? _bot['description']) as String?;
  // The raw token is only ever returned at creation/regeneration time; viewing
  // a bot later won't have it (the server stores only a hash).
  String get _token => (_bot['api_token'] ?? _bot['token']) as String? ?? '';

  void _copyToken() {
    if (_token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Token is only shown once. Use “Regenerate” to issue a new one.')),
      );
      return;
    }
    Clipboard.setData(ClipboardData(text: _token));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Token copied to clipboard')),
    );
  }

  Future<void> _regenerateToken() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Regenerate API token?'),
        content: const Text(
            'A new token will be issued and the current one will stop working '
            'immediately. Update any running bot with the new token.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Regenerate')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final token = await api.regenerateBotToken(_bot['id'] as String);
      if (!mounted) return;
      setState(() => _bot = {..._bot, 'api_token': token});
      _showNewToken(token);
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Failed to regenerate: $e')));
    }
  }

  void _showNewToken(String token) {
    showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('New API Token'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Copy this now — it will not be shown again.',
                style: TextStyle(
                    color: Colors.orange, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              _CredentialField(
                  label: 'API Token', value: token, monospace: true),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: token));
              Navigator.pop(ctx);
            },
            child: const Text('Copy & close'),
          ),
        ],
      ),
    );
  }

  void _editBot() {
    final descCtrl = TextEditingController(text: _description ?? '');
    final webhookCtrl = TextEditingController(
      text: _bot['webhook_url'] as String? ?? '',
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Edit Bot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: webhookCtrl,
              decoration: const InputDecoration(
                labelText: 'Webhook URL (optional)',
                hintText: 'https://your-server.com/webhook',
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final desc = descCtrl.text.trim();
              final webhook = webhookCtrl.text.trim();
              final api = context.read<ApiService>();
              Navigator.pop(ctx);
              try {
                await api.updateBot(
                  _bot['id'] as String,
                  description: desc.isEmpty ? null : desc,
                  webhookUrl: webhook.isEmpty ? null : webhook,
                );
                if (mounted) {
                  setState(() {
                    _bot = {
                      ..._bot,
                      'bio': desc.isEmpty ? null : desc,
                      if (webhook.isNotEmpty) 'webhook_url': webhook,
                    };
                  });
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to update: $e')),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeAvatar() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final api = context.read<ApiService>();
    try {
      final bytes = await picked.readAsBytes();
      final url =
          await api.uploadAvatar(fileBytes: bytes, filename: picked.name);
      await api.updateBot(_bot['id'] as String, avatarUrl: url);
      if (mounted) {
        setState(() {
          _bot = {..._bot, 'avatar_url': url};
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update avatar: $e')),
        );
      }
    }
  }

  Future<void> _deleteBot() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Delete bot?'),
        content: Text(
            'This will permanently delete @$_username. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final api = context.read<ApiService>();
    try {
      await api.deleteBot(_bot['id'] as String);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete bot: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassAppBar(
        title: Text('@$_username'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit bot',
            onPressed: _editBot,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _changeAvatar,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 48,
                        backgroundImage: _avatarUrl != null
                            ? CachedNetworkImageProvider(
                                ApiConfig.resolveMedia(_avatarUrl!))
                            : null,
                        child: _avatarUrl == null
                            ? Text(
                                _username.isNotEmpty
                                    ? _username[0].toUpperCase()
                                    : 'B',
                                style: const TextStyle(fontSize: 32),
                              )
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor:
                              Theme.of(context).colorScheme.primary,
                          child: const Icon(Icons.camera_alt,
                              size: 16, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text('@$_username',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w600)),
                if (_description != null && _description!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
                    child: Text(
                      _description!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.55),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _BotDetailTile(
                  icon: Icons.vpn_key_outlined,
                  title: 'API Token',
                  subtitle: _token.isNotEmpty
                      ? '${_token.substring(0, _token.length.clamp(0, 20))}…'
                      : 'Shown only once. Regenerate to issue a new token.',
                  subtitleMono: _token.isNotEmpty,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_token.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.copy, size: 20),
                          tooltip: 'Copy token',
                          onPressed: _copyToken,
                        ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        tooltip: 'Regenerate token',
                        onPressed: _regenerateToken,
                      ),
                    ],
                  ),
                  onTap: _token.isNotEmpty ? _copyToken : _regenerateToken,
                ),
                Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: 66,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.10),
                ),
                _BotDetailTile(
                  icon: Icons.webhook_outlined,
                  title: 'Webhook URL',
                  subtitle: (_bot['webhook_url'] as String?)?.isNotEmpty == true
                      ? _bot['webhook_url'] as String
                      : 'Not configured',
                  trailingIcon: Icons.edit_outlined,
                  onTap: _editBot,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            tint:
                Theme.of(context).colorScheme.error.withValues(alpha: 0.06),
            padding: EdgeInsets.zero,
            child: _BotDetailTile(
              icon: Icons.delete_outline,
              title: 'Delete Bot',
              isDestructive: true,
              onTap: _deleteBot,
            ),
          ),
        ],
      ),
    );
  }
}

class _BotDetailTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool subtitleMono;
  final Widget? trailing;
  final IconData? trailingIcon;
  final VoidCallback? onTap;
  final bool isDestructive;

  const _BotDetailTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleMono = false,
    this.trailing,
    this.trailingIcon,
    this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isDestructive ? scheme.error : scheme.primary;
    return ClipRRect(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
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
                          color: isDestructive ? color : null,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: subtitleMono ? 'monospace' : null,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                    ],
                  ),
                ),
                ?trailing,
                if (trailingIcon != null)
                  Icon(trailingIcon, size: 18,
                      color: scheme.onSurface.withValues(alpha: 0.35)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CredentialField extends StatelessWidget {
  final String label;
  final String value;
  final bool monospace;
  final int maxLines;

  const _CredentialField({
    required this.label,
    required this.value,
    this.monospace = false,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            value,
            maxLines: maxLines,
            overflow: TextOverflow.fade,
            style: TextStyle(
              fontFamily: monospace ? 'monospace' : null,
              fontSize: 12,
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Copy', style: TextStyle(fontSize: 12)),
            onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          ),
        ),
      ],
    );
  }
}
