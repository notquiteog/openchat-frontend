import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/story.dart';
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
