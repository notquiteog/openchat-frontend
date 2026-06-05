import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../crypto/pgp_service.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/secure_storage_service.dart';
import 'glass.dart';

class ConversationInfoPanel extends StatefulWidget {
  final Conversation conversation;
  final String currentUserId;
  final List<Message> messages;
  final ValueChanged<Message>? onMessageSelected;
  final ValueChanged<SharedContentSection>? onSharedSectionOpen;

  const ConversationInfoPanel({
    super.key,
    required this.conversation,
    required this.currentUserId,
    this.messages = const [],
    this.onMessageSelected,
    this.onSharedSectionOpen,
  });

  @override
  State<ConversationInfoPanel> createState() => _ConversationInfoPanelState();
}

class _ConversationInfoPanelState extends State<ConversationInfoPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _sections = [
    SharedContentSection.media,
    SharedContentSection.files,
    SharedContentSection.links,
    SharedContentSection.voice,
    SharedContentSection.polls,
    SharedContentSection.payments,
    SharedContentSection.checklists,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _sections.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.conversation.displayName(widget.currentUserId);
    final avatar = widget.conversation.displayAvatar(widget.currentUserId);
    final description = widget.conversation.description?.trim();
    final scheme = Theme.of(context).colorScheme;
    final sharedHeight = (MediaQuery.sizeOf(context).height * 0.26)
        .clamp(168.0, 264.0)
        .toDouble();
    final grouped = {
      for (final section in _sections) section: _sharedItemsFor(section),
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.22),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: CircleAvatar(
              key: const Key('conversation-info-avatar'),
              radius: 42,
              backgroundImage: avatar != null && avatar.isNotEmpty
                  ? CachedNetworkImageProvider(ApiConfig.resolveMedia(avatar))
                  : null,
              child: avatar == null || avatar.isEmpty
                  ? Icon(
                      widget.conversation.isChannel
                          ? Icons.campaign
                          : widget.conversation.isGroup
                          ? Icons.group
                          : Icons.person,
                      size: 34,
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.60),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '${widget.conversation.members.length} member${widget.conversation.members.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.50),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Shared content',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withValues(alpha: 0.86),
                  ),
                ),
              ),
              if (widget.onSharedSectionOpen != null)
                TextButton.icon(
                  onPressed: () {
                    final section = _sections[_tabController.index];
                    widget.onSharedSectionOpen!(section);
                  },
                  icon: const Icon(Icons.open_in_full_rounded, size: 16),
                  label: const Text('View all'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.26),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.36),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerHeight: 0,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(16),
              ),
              labelColor: scheme.primary,
              unselectedLabelColor: scheme.onSurface.withValues(alpha: 0.62),
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              tabs: [
                for (final section in _sections)
                  Tab(
                    child: _SharedTabLabel(
                      section: section,
                      count: grouped[section]!.length,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: sharedHeight,
            child: TabBarView(
              controller: _tabController,
              children: [
                for (final section in _sections)
                  _SharedItemsList(
                    section: section,
                    items: grouped[section]!,
                    onTap: widget.onMessageSelected,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<_SharedItem> _sharedItemsFor(SharedContentSection section) {
    return _sharedItemsForSection(section, widget.messages);
  }
}

enum SharedContentSection {
  media('media'),
  files('files'),
  links('links'),
  voice('voice'),
  polls('polls'),
  payments('payments'),
  checklists('checklists');

  final String apiValue;

  const SharedContentSection(this.apiValue);
}

Future<void> showSharedContentSheet(
  BuildContext context, {
  required Conversation conversation,
  required String currentUserId,
  required bool channel,
  SharedContentSection initialSection = SharedContentSection.media,
  List<Message> initialMessages = const [],
  ValueChanged<Message>? onMessageSelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    builder: (_) => _SharedContentSheet(
      conversation: conversation,
      currentUserId: currentUserId,
      channel: channel,
      initialSection: initialSection,
      initialMessages: initialMessages,
      onMessageSelected: onMessageSelected,
    ),
  );
}

List<_SharedItem> _sharedItemsForSection(
  SharedContentSection section,
  List<Message> messages,
) {
  final items = <_SharedItem>[];
  for (final message in messages.reversed) {
    final content = message.content;
    switch (section) {
      case SharedContentSection.media:
        if (_isMediaMessage(message) && content?.hasAttachment == true) {
          items.add(
            _SharedItem(
              message: message,
              icon: _iconForMessage(message),
              title: _attachmentTitle(message, content!),
              subtitle: _captionOrSender(message),
              detail: _metaLabel(message, content: content),
            ),
          );
        }
        break;
      case SharedContentSection.files:
        if (_isFileMessage(message) && content?.hasAttachment == true) {
          items.add(
            _SharedItem(
              message: message,
              icon: _iconForMessage(message),
              title: _attachmentTitle(message, content!),
              subtitle: _captionOrSender(message),
              detail: _metaLabel(message, content: content),
            ),
          );
        }
        break;
      case SharedContentSection.links:
        final text = content?.text.trim() ?? '';
        for (final url in _extractLinks(text)) {
          items.add(
            _SharedItem(
              message: message,
              icon: Icons.link_rounded,
              title: url,
              subtitle: _trimAroundLink(text, url),
              detail: _dateLabel(message.createdAt),
            ),
          );
        }
        break;
      case SharedContentSection.voice:
        if (_isVoiceMessage(message) && content?.hasAttachment == true) {
          items.add(
            _SharedItem(
              message: message,
              icon: Icons.graphic_eq_rounded,
              title: message.type == MessageType.voice
                  ? 'Voice note'
                  : _attachmentTitle(message, content!),
              subtitle: _captionOrSender(message),
              detail: _metaLabel(message, content: content),
            ),
          );
        }
        break;
      case SharedContentSection.polls:
        final poll = message.poll;
        if (message.type == MessageType.poll && poll != null) {
          items.add(
            _SharedItem(
              message: message,
              icon: Icons.poll_outlined,
              title: poll.question.isEmpty ? 'Poll' : poll.question,
              subtitle: '${poll.options.length} options',
              detail:
                  '${poll.totalVoterCount} vote${poll.totalVoterCount == 1 ? '' : 's'}',
            ),
          );
        }
        break;
      case SharedContentSection.payments:
        if (message.type == MessageType.invoice ||
            message.type == MessageType.paymentRequest ||
            message.type == MessageType.paymentTransfer) {
          items.add(
            _SharedItem(
              message: message,
              icon: Icons.payments_outlined,
              title: _paymentTitle(message),
              subtitle: _paymentSubtitle(message),
              detail: _dateLabel(message.createdAt),
            ),
          );
        }
        break;
      case SharedContentSection.checklists:
        if (message.type == MessageType.checklist) {
          items.add(
            _SharedItem(
              message: message,
              icon: Icons.checklist_rounded,
              title: _checklistTitle(message),
              subtitle: _captionOrSender(message),
              detail: _dateLabel(message.createdAt),
            ),
          );
        }
        break;
    }
  }
  return items;
}

class _SharedItem {
  final Message message;
  final IconData icon;
  final String title;
  final String subtitle;
  final String detail;

  const _SharedItem({
    required this.message,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.detail,
  });
}

class _SharedTabLabel extends StatelessWidget {
  final SharedContentSection section;
  final int count;

  const _SharedTabLabel({required this.section, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_sectionIcon(section), size: 16),
        const SizedBox(width: 6),
        Text(_sectionLabel(section)),
        const SizedBox(width: 5),
        Text(count.toString()),
      ],
    );
  }
}

class _SharedItemsList extends StatelessWidget {
  final SharedContentSection section;
  final List<_SharedItem> items;
  final ValueChanged<Message>? onTap;

  const _SharedItemsList({
    required this.section,
    required this.items,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.20),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.28),
            ),
          ),
          child: Text(
            'No ${_sectionLabel(section).toLowerCase()}',
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.55),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        return _SharedItemTile(item: item, onTap: onTap);
      },
    );
  }
}

class _SharedItemTile extends StatelessWidget {
  final _SharedItem item;
  final ValueChanged<Message>? onTap;

  const _SharedItemTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.28),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap == null ? null : () => onTap!(item.message),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(item.icon, color: scheme.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.90),
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    if (item.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: 0.58),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                item.detail,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.46),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SharedContentSheet extends StatefulWidget {
  final Conversation conversation;
  final String currentUserId;
  final bool channel;
  final SharedContentSection initialSection;
  final List<Message> initialMessages;
  final ValueChanged<Message>? onMessageSelected;

  const _SharedContentSheet({
    required this.conversation,
    required this.currentUserId,
    required this.channel,
    required this.initialSection,
    required this.initialMessages,
    required this.onMessageSelected,
  });

  @override
  State<_SharedContentSheet> createState() => _SharedContentSheetState();
}

class _SharedContentSheetState extends State<_SharedContentSheet>
    with SingleTickerProviderStateMixin {
  static const _sections = [
    SharedContentSection.media,
    SharedContentSection.files,
    SharedContentSection.links,
    SharedContentSection.voice,
    SharedContentSection.polls,
    SharedContentSection.payments,
    SharedContentSection.checklists,
  ];

  late final TabController _tabController;
  final _sectionStates = <SharedContentSection, _SharedContentLoadState>{};

  SharedContentSection get _currentSection => _sections[_tabController.index];

  @override
  void initState() {
    super.initState();
    final initialIndex = math.max(0, _sections.indexOf(widget.initialSection));
    _tabController = TabController(
      length: _sections.length,
      vsync: this,
      initialIndex: initialIndex,
    )..addListener(_handleTabChanged);
    _seedLocalLinks();
    unawaited(_ensureLoaded(_currentSection));
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    if (_tabController.indexIsChanging) return;
    unawaited(_ensureLoaded(_currentSection));
  }

  _SharedContentLoadState _stateFor(SharedContentSection section) {
    return _sectionStates.putIfAbsent(section, _SharedContentLoadState.new);
  }

  void _seedLocalLinks() {
    final state = _stateFor(SharedContentSection.links);
    state
      ..messages = List<Message>.of(widget.initialMessages)
      ..initialized = true
      ..loading = false
      ..error = null;
  }

  void _seedLocalSection(SharedContentSection section) {
    final state = _stateFor(section);
    state
      ..messages = List<Message>.of(widget.initialMessages)
      ..nextCursor = null
      ..initialized = true
      ..loading = false
      ..loadingMore = false
      ..error = null;
  }

  Future<void> _ensureLoaded(
    SharedContentSection section, {
    bool refresh = false,
  }) async {
    final state = _stateFor(section);
    if (widget.conversation.isEncrypted) {
      if (!state.initialized || refresh) {
        setState(() => _seedLocalSection(section));
      }
      return;
    }
    if (section == SharedContentSection.links) {
      if (!state.initialized || refresh) {
        setState(_seedLocalLinks);
      }
      return;
    }

    if (state.loading || (state.initialized && !refresh)) return;

    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    setState(() {
      state
        ..loading = true
        ..error = null;
      if (refresh) {
        state
          ..messages = const []
          ..nextCursor = null
          ..initialized = false;
      }
    });

    try {
      final privateKeyFuture = storage.getPrivateKeyIfUnlocked();
      final page = await api.getSharedContent(
        widget.conversation.id,
        section: section.apiValue,
        channel: widget.channel,
        limit: 60,
      );
      final privateKey = await privateKeyFuture ?? '';
      final hydrated = await Future.wait(
        page.items.map((message) => _hydrateSharedMessage(message, privateKey)),
      );
      if (!mounted) return;
      setState(() {
        state
          ..messages = hydrated.reversed.toList()
          ..nextCursor = page.nextCursor
          ..initialized = true
          ..loading = false
          ..error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state
          ..loading = false
          ..initialized = true
          ..error = e.toString();
      });
    }
  }

  Future<void> _loadMore(SharedContentSection section) async {
    if (widget.conversation.isEncrypted) return;
    if (section == SharedContentSection.links) return;
    final state = _stateFor(section);
    final cursor = state.nextCursor;
    if (cursor == null || state.loadingMore) return;

    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    setState(() {
      state
        ..loadingMore = true
        ..error = null;
    });

    try {
      final privateKeyFuture = storage.getPrivateKeyIfUnlocked();
      final page = await api.getSharedContent(
        widget.conversation.id,
        section: section.apiValue,
        channel: widget.channel,
        beforeID: cursor,
        limit: 60,
      );
      final privateKey = await privateKeyFuture ?? '';
      final hydrated = await Future.wait(
        page.items.map((message) => _hydrateSharedMessage(message, privateKey)),
      );
      if (!mounted) return;
      setState(() {
        state
          ..messages = [...hydrated.reversed, ...state.messages]
          ..nextCursor = page.nextCursor
          ..loadingMore = false
          ..error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state
          ..loadingMore = false
          ..error = e.toString();
      });
    }
  }

  Future<Message> _hydrateSharedMessage(
    Message message,
    String privateKey,
  ) async {
    if (message.type == MessageType.poll || !message.isEncrypted) {
      message.setDecryptedContent(message.encryptedPayload);
      return message;
    }
    if (privateKey.isEmpty) return message;
    try {
      final raw = await PgpService.decrypt(
        encryptedArmor: message.encryptedPayload,
        privateKeyArmored: privateKey,
      );
      if (raw.isNotEmpty) {
        message.setDecryptedContent(raw);
      } else {
        message.markDecryptionFailed();
      }
    } catch (_) {
      message.markDecryptionFailed();
    }
    return message;
  }

  void _selectMessage(Message message) {
    Navigator.pop(context);
    widget.onMessageSelected?.call(message);
  }

  void _refreshCurrent() {
    unawaited(_ensureLoaded(_currentSection, refresh: true));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = (MediaQuery.sizeOf(context).height * 0.74)
        .clamp(360.0, 680.0)
        .toDouble();
    final name = widget.conversation.displayName(widget.currentUserId);

    return GlassBottomSheetFrame(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      includeKeyboardInset: false,
      scrollable: false,
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary.withValues(alpha: 0.14),
                  ),
                  child: Icon(
                    Icons.photo_library_outlined,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Shared content',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: _stateFor(_currentSection).loading
                      ? null
                      : _refreshCurrent,
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.26),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.36),
                ),
              ),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerHeight: 0,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(16),
                ),
                labelColor: scheme.primary,
                unselectedLabelColor: scheme.onSurface.withValues(alpha: 0.62),
                labelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                tabs: [
                  for (final section in _sections)
                    Tab(
                      child: _SharedTabLabel(
                        section: section,
                        count: _sharedItemsForSection(
                          section,
                          _stateFor(section).messages,
                        ).length,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  for (final section in _sections) _buildSection(section),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(SharedContentSection section) {
    final state = _stateFor(section);
    final items = _sharedItemsForSection(section, state.messages);
    if (state.loading && !state.initialized) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && items.isEmpty) {
      return _SharedStateMessage(
        icon: Icons.error_outline_rounded,
        title: 'Could not load ${_sectionLabel(section).toLowerCase()}',
        subtitle: state.error!,
        action: TextButton.icon(
          onPressed: () => unawaited(_ensureLoaded(section, refresh: true)),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: _SharedItemsList(
            section: section,
            items: items,
            onTap: _selectMessage,
          ),
        ),
        if (section != SharedContentSection.links &&
            (state.nextCursor != null || state.loadingMore)) ...[
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: state.loadingMore
                ? null
                : () => unawaited(_loadMore(section)),
            icon: state.loadingMore
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.expand_more_rounded),
            label: Text(state.loadingMore ? 'Loading' : 'Load more'),
          ),
        ],
      ],
    );
  }
}

class _SharedContentLoadState {
  List<Message> messages = const [];
  String? nextCursor;
  bool initialized = false;
  bool loading = false;
  bool loadingMore = false;
  String? error;
}

class _SharedStateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const _SharedStateMessage({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.20),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.28),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: scheme.primary, size: 28),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.86),
                fontWeight: FontWeight.w800,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                subtitle!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.58),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 10), action!],
          ],
        ),
      ),
    );
  }
}

bool _isMediaMessage(Message message) {
  return switch (message.type) {
    MessageType.image ||
    MessageType.video ||
    MessageType.animation ||
    MessageType.videoNote ||
    MessageType.livePhoto => true,
    _ => false,
  };
}

bool _isVoiceMessage(Message message) {
  return message.type == MessageType.voice || message.type == MessageType.audio;
}

bool _isFileMessage(Message message) {
  return message.type == MessageType.file && !_isMediaMessage(message);
}

IconData _iconForMessage(Message message) {
  return switch (message.type) {
    MessageType.image => Icons.image_outlined,
    MessageType.video ||
    MessageType.videoNote ||
    MessageType.livePhoto => Icons.play_circle_outline_rounded,
    MessageType.animation => Icons.gif_box_outlined,
    MessageType.audio || MessageType.voice => Icons.graphic_eq_rounded,
    _ => Icons.insert_drive_file_outlined,
  };
}

IconData _sectionIcon(SharedContentSection section) {
  return switch (section) {
    SharedContentSection.media => Icons.photo_library_outlined,
    SharedContentSection.files => Icons.folder_outlined,
    SharedContentSection.links => Icons.link_rounded,
    SharedContentSection.voice => Icons.graphic_eq_rounded,
    SharedContentSection.polls => Icons.poll_outlined,
    SharedContentSection.payments => Icons.payments_outlined,
    SharedContentSection.checklists => Icons.checklist_rounded,
  };
}

String _sectionLabel(SharedContentSection section) {
  return switch (section) {
    SharedContentSection.media => 'Media',
    SharedContentSection.files => 'Files',
    SharedContentSection.links => 'Links',
    SharedContentSection.voice => 'Voice',
    SharedContentSection.polls => 'Polls',
    SharedContentSection.payments => 'Payments',
    SharedContentSection.checklists => 'Lists',
  };
}

String _attachmentTitle(Message message, MessageContent content) {
  final fileName = content.fileName?.trim();
  if (fileName != null && fileName.isNotEmpty) return fileName;
  return switch (message.type) {
    MessageType.image => 'Image',
    MessageType.video => 'Video',
    MessageType.audio => 'Audio',
    MessageType.voice => 'Voice note',
    _ => 'File',
  };
}

String _captionOrSender(Message message) {
  final text = message.content?.text.trim() ?? '';
  if (text.isNotEmpty) return text;
  return message.sender?.username ?? '';
}

String _metaLabel(Message message, {MessageContent? content}) {
  final parts = <String>[];
  final duration = content?.durationMs;
  if (duration != null && duration > 0) {
    parts.add(_durationLabel(Duration(milliseconds: duration)));
  }
  final size = content?.fileSize;
  if (size != null && size > 0) parts.add(_fileSizeLabel(size));
  parts.add(_dateLabel(message.createdAt));
  return parts.join(' - ');
}

String _dateLabel(DateTime date) {
  return DateFormat('MMM d').format(date.toLocal());
}

String _fileSizeLabel(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  if (unit == 0) return '${size.round()} ${units[unit]}';
  return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unit]}';
}

String _durationLabel(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

Iterable<String> _extractLinks(String text) {
  if (text.isEmpty) return const [];
  final regex = RegExp(r'https?://[^\s<>()]+', caseSensitive: false);
  return regex.allMatches(text).map((match) => match.group(0)!).toList();
}

String _trimAroundLink(String text, String url) {
  final cleaned = text.replaceFirst(url, '').trim();
  if (cleaned.isEmpty) return '';
  return cleaned.length <= 92 ? cleaned : '${cleaned.substring(0, 89)}...';
}

String _paymentTitle(Message message) {
  final raw = message.decryptedPayload ?? message.encryptedPayload;
  if (raw.contains('"transfer"')) return 'Payment sent';
  if (raw.contains('"invoice"')) return 'Invoice';
  return 'Payment request';
}

String _paymentSubtitle(Message message) {
  final preview = message.decryptedContent?.trim();
  if (preview != null && preview.isNotEmpty) return preview;
  return message.sender?.username ?? '';
}

String _checklistTitle(Message message) {
  final text = message.decryptedContent?.trim();
  if (text == null || text.isEmpty) return 'Checklist';
  return text.length <= 64 ? text : '${text.substring(0, 61)}...';
}
