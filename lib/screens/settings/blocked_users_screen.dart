import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../models/user.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';

/// Lists everyone the signed-in user has blocked, paged from the server with
/// infinite scroll and an inline Unblock action. A block list can grow
/// unbounded, so it is never loaded as a single flat dump.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  static const _pageSize = 50;

  final _scrollCtrl = ScrollController();
  final List<User> _users = [];
  final Set<String> _unblocking = {};
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  bool get _hasMore => _users.length < _total;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 480) _loadMore();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<ApiService>().listBlockedUsers(
        limit: _pageSize,
        offset: 0,
      );
      if (!mounted) return;
      setState(() {
        _users
          ..clear()
          ..addAll(page.users);
        _total = page.total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<ApiService>().listBlockedUsers(
        limit: _pageSize,
        offset: _users.length,
      );
      if (!mounted) return;
      setState(() {
        // Dedupe by id — offset paging can shift if a block is removed while
        // scrolling, which is fine for a personal list.
        final seen = _users.map((u) => u.id).toSet();
        _users.addAll(page.users.where((u) => !seen.contains(u.id)));
        _total = page.total;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _unblock(User user) async {
    if (_unblocking.contains(user.id)) return;
    setState(() => _unblocking.add(user.id));
    try {
      await context.read<ApiService>().unblockUser(user.id);
      if (!mounted) return;
      setState(() {
        _users.removeWhere((u) => u.id == user.id);
        if (_total > 0) _total -= 1;
        _unblocking.remove(user.id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _unblocking.remove(user.id));
      showAppToast(context, 'Could not unblock', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassAppBar(title: const Text('Blocked users')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: GlassProgressIndicator.circular());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Could not load your block list.'),
            const SizedBox(height: 16),
            GlassButtonWidget(
              onPressed: _loadFirstPage,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_users.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.block_rounded,
              size: 44,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const Text("You haven't blocked anyone."),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      itemCount: _users.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _users.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: GlassProgressIndicator.circular(size: 22)),
          );
        }
        final user = _users[index];
        return _BlockedRow(
          user: user,
          busy: _unblocking.contains(user.id),
          onUnblock: () => _unblock(user),
        );
      },
    );
  }
}

class _BlockedRow extends StatelessWidget {
  final User user;
  final bool busy;
  final VoidCallback onUnblock;

  const _BlockedRow({
    required this.user,
    required this.busy,
    required this.onUnblock,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = user.avatarUrl;
    return GlassListTile(
      leading: CircleAvatar(
        backgroundImage: avatar != null && avatar.isNotEmpty
            ? NetworkImage(ApiConfig.resolveMedia(avatar))
            : null,
        child: avatar == null || avatar.isEmpty
            ? Text(user.avatarInitial)
            : null,
      ),
      title: Text(user.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(user.handle),
      trailing: GlassButtonWidget(
        onPressed: busy ? null : onUnblock,
        child: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: GlassProgressIndicator.circular(size: 16, strokeWidth: 2),
              )
            : const Text('Unblock'),
      ),
    );
  }
}
