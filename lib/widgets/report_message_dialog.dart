import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import 'glass.dart';

/// Shows the report-destination chooser shared by group/DM chat messages and
/// channel posts, then performs the selected report(s). Every message is
/// reportable: the **Platform admins** destination is always available.
///
/// Destinations:
///  - **Platform admins** — a report to the platform's moderators (a.k.a. the
///    system admins; these are the same people, so there is one destination,
///    not two). Routed to them only, bypassing the chat's own admins. Always
///    available. For end-to-end-encrypted messages the moderators get your
///    reason + identity but not the content; for non-encrypted messages they
///    can read the content directly. When this message carries a valid
///    AMF/Hecate franking proof ([csamBlob] non-null), a nested **"This is
///    child sexual abuse material"** option upgrades it to an anonymous,
///    provable (deanonymizable) CSAM report instead of the identity-attached
///    one.
///  - **Channel/Group admins** — a general report to this chat's own admins.
///    Shown when [hasAdmins] is true (groups and channels).
///
/// [isChannel] selects the "Channel admins" wording and the channel flag on the
/// moderation-report API. [messageEncrypted] tailors the platform-admins blurb.
Future<void> showReportMessageDialog({
  required BuildContext context,
  required String conversationId,
  required String messageId,
  required String? reportedUserId,
  required bool isChannel,
  required bool hasAdmins,
  required bool messageEncrypted,
  required Map<String, dynamic>? csamBlob,
}) async {
  // The anonymous, provable CSAM report (to system admins) is only possible
  // when this message's AMF franking verified as valid on receipt.
  final canCsam = csamBlob != null;

  var toPlatform = false; // report to the platform admins / moderators
  var asCsam = false; // file the platform report as the provable CSAM report
  var toGroup = false; // report to this chat's own admins (target: admins)
  final reasonCtrl = TextEditingController();

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final needsReason = (toPlatform && !asCsam) || toGroup;
        final canSubmit = toPlatform || toGroup;
        return GlassAlertDialog(
          title: const Text('Report message'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Send this report to:'),
              const SizedBox(height: 8),
              _ReportDestinationTile(
                icon: Icons.shield_outlined,
                title: 'Platform admins',
                subtitle: messageEncrypted
                    ? 'A report to the platform’s moderators. Your identity '
                          'and reason are shared; the encrypted content is not.'
                    : 'A report to the platform’s moderators, who can act '
                          'across any chat. This message is not encrypted.',
                value: toPlatform,
                enabled: true,
                onChanged: (v) => setLocal(() {
                  toPlatform = v;
                  if (!v) asCsam = false;
                }),
              ),
              if (toPlatform && canCsam)
                Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: _ReportDestinationTile(
                    icon: Icons.report_gmailerrorred_outlined,
                    title: 'This is child sexual abuse material',
                    subtitle:
                        'Send an anonymous, provable report instead of a '
                        'standard one. Use ONLY for CSAM.',
                    value: asCsam,
                    enabled: true,
                    onChanged: (v) => setLocal(() => asCsam = v),
                  ),
                ),
              if (hasAdmins)
                _ReportDestinationTile(
                  icon: Icons.groups_outlined,
                  title: isChannel ? 'Channel admins' : 'Group admins',
                  subtitle:
                      'A general report to this chat’s admins. Your identity '
                      'is visible to them.',
                  value: toGroup,
                  enabled: true,
                  onChanged: (v) => setLocal(() => toGroup = v),
                ),
              if (needsReason) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: reasonCtrl,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Reason (shared with the admins you selected)',
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: canSubmit ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Report'),
            ),
          ],
        );
      },
    ),
  );
  final reason = reasonCtrl.text.trim();
  reasonCtrl.dispose();
  if (confirmed != true || !context.mounted) return;

  final api = context.read<ApiService>();
  var anyOk = false;
  var anyErr = false;
  if (toPlatform) {
    try {
      if (asCsam && csamBlob != null) {
        // Anonymous, provable CSAM report (AMF/Hecate) to the platform
        // moderators — replaces the identity-attached moderation report.
        await api.reportCsam(csamBlob);
      } else {
        await api.createModerationReport(
          conversationId,
          channel: isChannel,
          messageID: messageId,
          reportedUserID: reportedUserId,
          reason: reason,
          target: 'system',
        );
      }
      anyOk = true;
    } catch (_) {
      anyErr = true;
    }
  }
  if (toGroup) {
    try {
      await api.createModerationReport(
        conversationId,
        channel: isChannel,
        messageID: messageId,
        reportedUserID: reportedUserId,
        reason: reason,
        target: 'admins',
      );
      anyOk = true;
    } catch (_) {
      anyErr = true;
    }
  }
  if (!context.mounted) return;
  if (anyErr) {
    showAppToast(context, 'Failed to send report', isError: true);
  } else if (anyOk) {
    showAppToast(context, 'Report sent');
  }
}

class _ReportDestinationTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ReportDestinationTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: GlassListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: IgnorePointer(
          ignoring: !enabled,
          child: GlassSwitch(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}
