import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/story.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../services/api_service.dart';
import 'glass.dart';

/// Outcome of the author-only story manage sheet.
enum StoryManageResult { unchanged, updated, deleted }

class StoryManageOutcome {
  final StoryManageResult result;

  /// The fresh story row for pin/archive toggles; null for unchanged/deleted.
  final Story? story;

  const StoryManageOutcome(this.result, [this.story]);

  static const unchanged = StoryManageOutcome(StoryManageResult.unchanged);
}

/// Presents the author-only manage actions for [story] (pin/unpin,
/// archive/unarchive, delete) and performs the chosen action, returning the
/// outcome so the caller can reconcile its local list. The backend already
/// gates all three actions to the author/admin; this is the missing UI.
Future<StoryManageOutcome> showStoryManageSheet(
  BuildContext context,
  Story story,
) async {
  final api = context.read<ApiService>();
  final archived = story.archivedAt != null;
  String? choice;
  await showGlassActionSheet<void>(
    context: context,
    title: 'Manage story',
    actions: [
      GlassActionSheetAction(
        label: story.pinned ? 'Unpin from profile' : 'Pin to profile',
        icon: Icon(story.pinned ? Icons.push_pin : Icons.push_pin_outlined),
        onPressed: () => choice = 'pin',
      ),
      GlassActionSheetAction(
        label: archived ? 'Unarchive' : 'Archive',
        icon: Icon(
          archived ? Icons.unarchive_outlined : Icons.archive_outlined,
        ),
        onPressed: () => choice = 'archive',
      ),
      // Audience editing only applies to personal stories — channel stories are
      // governed by channel membership, not a per-story allow/deny list.
      if (story.conversationId == null)
        GlassActionSheetAction(
          label: 'Edit who can see this',
          icon: const Icon(Icons.visibility_outlined),
          onPressed: () => choice = 'audience',
        ),
      GlassActionSheetAction(
        label: 'Delete story',
        icon: const Icon(Icons.delete_outline_rounded),
        style: GlassActionSheetStyle.destructive,
        onPressed: () => choice = 'delete',
      ),
    ],
  );

  if (choice == null || !context.mounted) return StoryManageOutcome.unchanged;

  try {
    switch (choice) {
      case 'pin':
        final updated = await api.pinStory(story.id, !story.pinned);
        return StoryManageOutcome(StoryManageResult.updated, updated);
      case 'archive':
        final updated = await api.archiveStory(story.id, !archived);
        return StoryManageOutcome(StoryManageResult.updated, updated);
      case 'audience':
        if (!context.mounted) return StoryManageOutcome.unchanged;
        final updated = await _editStoryAudience(context, story);
        return updated == null
            ? StoryManageOutcome.unchanged
            : StoryManageOutcome(StoryManageResult.updated, updated);
      case 'delete':
        if (!context.mounted || !await _confirmDelete(context)) {
          return StoryManageOutcome.unchanged;
        }
        await api.deleteStory(story.id);
        return const StoryManageOutcome(StoryManageResult.deleted);
    }
  } catch (_) {
    if (context.mounted) {
      showAppToast(context, 'Could not update story', isError: true);
    }
  }
  return StoryManageOutcome.unchanged;
}

/// Author-only editor for who can see a posted story (applies to the whole
/// reel). Maps the chosen tier/people to the privacy + allow/deny lists the
/// server enforces. Note: for end-to-end stories a newly-allowed person still
/// can't decrypt an already-sealed post — see store.UpdateStoryAudience.
Future<Story?> _editStoryAudience(BuildContext context, Story story) async {
  final api = context.read<ApiService>();
  final me = context.read<AuthProvider>().currentUser?.id ?? '';
  final chat = context.read<ChatProvider>();
  final contacts = <User>[];
  final seen = <String>{};
  for (final c in chat.conversations.where((c) => c.isDM)) {
    final u = c.otherUser(me);
    if (u != null && seen.add(u.id)) contacts.add(u);
  }

  // tier: 'contacts' | 'public' | 'custom' (custom uses mode + selection).
  var tier = switch (story.privacy) {
    'public' => 'public',
    'selected' => 'custom',
    _ => 'contacts',
  };
  var mode = story.privacy == 'selected' ? 'only' : 'except';
  final selected = <String>{};
  var save = false;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheet) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            const GlassSheetHeader(
              icon: Icons.visibility_outlined,
              title: 'Who can see this',
              subtitle: 'Applies to your whole story',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: GlassSegmentedControl(
                segments: const ['Contacts', 'Public', 'Custom'],
                selectedIndex: switch (tier) {
                  'public' => 1,
                  'custom' => 2,
                  _ => 0,
                },
                onSegmentSelected: (i) => setSheet(
                  () => tier = const ['contacts', 'public', 'custom'][i],
                ),
              ),
            ),
            if (tier == 'custom') ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: GlassSegmentedControl(
                  segments: const ['Only selected', 'All except'],
                  selectedIndex: mode == 'only' ? 0 : 1,
                  onSegmentSelected: (i) =>
                      setSheet(() => mode = i == 0 ? 'only' : 'except'),
                ),
              ),
              if (contacts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Start a DM with someone first to add them.'),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final u in contacts)
                        GlassListTile(
                          title: Text(u.displayName),
                          subtitle: Text('@${u.username}'),
                          trailing: GlassSwitch(
                            value: selected.contains(u.id),
                            onChanged: (v) => setSheet(() {
                              if (v) {
                                selected.add(u.id);
                              } else {
                                selected.remove(u.id);
                              }
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            Padding(
              padding: const EdgeInsets.all(12),
              child: GlassButtonWidget(
                onPressed: () {
                  save = true;
                  Navigator.pop(sheetCtx);
                },
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  if (!save || !context.mounted) return null;

  String privacy;
  List<String> allow = const [];
  List<String> block = const [];
  switch (tier) {
    case 'public':
      privacy = 'public';
    case 'custom':
      // Don't silently widen a custom story to "all contacts" on an empty
      // selection — treat that as a cancel instead.
      if (selected.isEmpty) return null;
      if (mode == 'only') {
        privacy = 'selected';
        allow = selected.toList();
      } else {
        privacy = 'contacts';
        block = selected.toList();
      }
    default:
      privacy = 'contacts';
  }
  try {
    return await api.updateStoryAudience(
      story.id,
      privacy: privacy,
      allowUserIds: allow,
      blockUserIds: block,
    );
  } catch (_) {
    if (context.mounted) {
      showAppToast(context, 'Could not update audience', isError: true);
    }
    return null;
  }
}

Future<bool> _confirmDelete(BuildContext context) async {
  bool confirmed = false;
  await showGlassActionSheet<void>(
    context: context,
    title: 'Delete this story?',
    message: "This permanently removes it for everyone and can't be undone.",
    actions: [
      GlassActionSheetAction(
        label: 'Delete',
        icon: const Icon(Icons.delete_outline_rounded),
        style: GlassActionSheetStyle.destructive,
        onPressed: () => confirmed = true,
      ),
    ],
  );
  return confirmed;
}
