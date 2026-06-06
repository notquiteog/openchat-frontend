import 'package:flutter/material.dart';

import '../services/attachment_service.dart';
import 'glass.dart';

class AttachmentUploadProgressChip extends StatelessWidget {
  final AttachmentUploadProgress progress;

  const AttachmentUploadProgressChip({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = progress.fraction;
    final percent = fraction == null ? null : (fraction * 100).round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: GlassContainer(
        shape: const LiquidRoundedSuperellipse(borderRadius: 22),
        allowElevation: true,
        glowIntensity: 0.05,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(_stageIcon(progress.stage), color: scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _stageLabel(progress.stage),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: 0.88),
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (percent != null)
                        Text(
                          '$percent%',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: 0.58),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  GlassProgressIndicator.linear(
                    value: fraction,
                    height: 5,
                    backgroundColor: scheme.surfaceContainerHighest
                        .withValues(alpha: 0.42),
                    color: scheme.primary,
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

IconData _stageIcon(AttachmentUploadStage stage) {
  return switch (stage) {
    AttachmentUploadStage.preparing => Icons.tune_rounded,
    AttachmentUploadStage.encrypting => Icons.lock_outline_rounded,
    AttachmentUploadStage.uploading => Icons.cloud_upload_outlined,
    AttachmentUploadStage.confirming => Icons.verified_outlined,
    AttachmentUploadStage.sending => Icons.send_outlined,
  };
}

String _stageLabel(AttachmentUploadStage stage) {
  return switch (stage) {
    AttachmentUploadStage.preparing => 'Preparing attachment',
    AttachmentUploadStage.encrypting => 'Encrypting attachment',
    AttachmentUploadStage.uploading => 'Uploading attachment',
    AttachmentUploadStage.confirming => 'Finishing upload',
    AttachmentUploadStage.sending => 'Sending message',
  };
}
