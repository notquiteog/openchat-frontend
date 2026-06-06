import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_service.dart';
import '../../widgets/glass.dart';

class MiniAppsScreen extends StatefulWidget {
  const MiniAppsScreen({super.key});

  @override
  State<MiniAppsScreen> createState() => _MiniAppsScreenState();
}

class _MiniAppsScreenState extends State<MiniAppsScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _searchTimer;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _apps = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final apps = await context.read<ApiService>().listMiniApps(
        query: _searchCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _apps = apps;
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

  void _queueSearch(String _) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 250), _load);
  }

  Future<void> _openApp(Map<String, dynamic> app) async {
    final url = app['url']?.toString() ?? '';
    final uri = Uri.tryParse(url);
    final messenger = ScaffoldMessenger.of(context);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Mini apps must use HTTPS')),
      );
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Mini app could not be opened')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GlassAppBar(title: Text('Mini Apps')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
          children: [
            TextField(
              controller: _searchCtrl,
              onChanged: _queueSearch,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search mini apps',
              ),
            ),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: GlassProgressIndicator.circular()),
              )
            else if (_error != null)
              GlassCard(
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else if (_apps.isEmpty)
              const GlassCard(child: Text('No mini apps found'))
            else
              GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var index = 0; index < _apps.length; index++)
                      _MiniAppTile(
                        app: _apps[index],
                        isLast: index == _apps.length - 1,
                        onTap: () => _openApp(_apps[index]),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniAppTile extends StatelessWidget {
  final Map<String, dynamic> app;
  final bool isLast;
  final VoidCallback onTap;

  const _MiniAppTile({
    required this.app,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = app['title']?.toString() ?? app['slug']?.toString() ?? 'App';
    final description = app['description']?.toString();
    final url = app['url']?.toString() ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.widgets_outlined),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            (description?.trim().isNotEmpty == true) ? description! : url,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(Icons.open_in_browser_rounded, color: scheme.primary),
          onTap: onTap,
        ),
        if (!isLast) const Divider(height: 1),
      ],
    );
  }
}
