import 'package:flutter/material.dart';

import 'glass.dart';

/// (sheet title, [(label, choice)…]) variants offered when an attachment tile is
/// held. The choice strings carry the flag prefix the send path reads
/// (`view_once_` / `spoiler_`) or the `location_once` / `location_live` values.
/// Shared by the DM and channel composers so the two stay in lockstep; kept
/// top-level so it stays unit-testable without pumping a screen.
(String, List<(String, String)>) attachmentVariantActions(String variants) =>
    switch (variants) {
      'photo_variants' => (
        'Send photo',
        [
          ('View-once photo', 'view_once_image'),
          ('Spoiler photo', 'spoiler_image'),
        ],
      ),
      'video_variants' => (
        'Send video',
        [
          ('View-once video', 'view_once_video'),
          ('Spoiler video', 'spoiler_video'),
        ],
      ),
      'file_variants' => ('Send file', [('View-once file', 'view_once_file')]),
      'location_variants' => (
        'Share location',
        [
          ('Send your location', 'location_once'),
          ('Share live location', 'location_live'),
        ],
      ),
      _ => ('', <(String, String)>[]),
    };

/// Holding an attachment tile (photo / video / file / location) opens this
/// grouped-glass sheet of "send as…" variants. Returns the chosen value, or
/// null if dismissed.
Future<String?> showAttachmentVariantSheet(
  BuildContext context,
  String variants,
) {
  final (title, actions) = attachmentVariantActions(variants);
  if (actions.isEmpty) return Future<String?>.value(null);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => GlassBottomSheetFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GlassSheetGrabber(),
          GlassSheetHeader(
            icon: _variantHeaderIcon(variants),
            title: title,
            subtitle: 'Choose how to send.',
            onClose: () => Navigator.pop(sheetCtx),
          ),
          const SizedBox(height: 4),
          GlassMenuSection(
            entries: [
              for (final (label, value) in actions)
                GlassMenuEntry(
                  icon: _attachmentVariantIcon(value),
                  label: label,
                  onTap: () => Navigator.pop(sheetCtx, value),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

IconData _variantHeaderIcon(String variants) => switch (variants) {
  'photo_variants' => Icons.photo_library_outlined,
  'video_variants' => Icons.videocam_outlined,
  'file_variants' => Icons.attach_file_rounded,
  'location_variants' => Icons.share_location_outlined,
  _ => Icons.add_rounded,
};

IconData _attachmentVariantIcon(String value) {
  if (value.startsWith('view_once_')) return Icons.timer_outlined;
  if (value.startsWith('spoiler_')) return Icons.visibility_off_outlined;
  return switch (value) {
    'location_once' => Icons.my_location_rounded,
    'location_live' => Icons.share_location_outlined,
    _ => Icons.attach_file_rounded,
  };
}
