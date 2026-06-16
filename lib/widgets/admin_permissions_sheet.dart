import 'package:flutter/material.dart';
import '../models/conversation.dart';
import 'glass.dart';

const _permissionLabels = {
  AdminPermission.manageInfo: 'Info and appearance',
  AdminPermission.manageSettings: 'Timers and settings',
  AdminPermission.manageEncryption: 'Encryption',
  AdminPermission.manageTopics: 'Topics',
  AdminPermission.manageMembers: 'Members',
  AdminPermission.manageRoles: 'Roles',
  AdminPermission.manageInvites: 'Invites',
  AdminPermission.approveJoinRequests: 'Join requests',
  AdminPermission.managePins: 'Pins',
  AdminPermission.deleteMessages: 'Delete messages',
  AdminPermission.manageModeration: 'Moderation',
  AdminPermission.postMessages: 'Post in broadcast mode',
};

Future<void> showAdminPermissionsSheet({
  required BuildContext context,
  required ConversationMember member,
  required Future<void> Function(MemberRole role, Map<String, bool> permissions)
  onSave,
  bool allowModerator = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AdminPermissionsSheet(
      member: member,
      onSave: onSave,
      allowModerator: allowModerator,
    ),
  );
}

class _AdminPermissionsSheet extends StatefulWidget {
  final ConversationMember member;
  final Future<void> Function(MemberRole role, Map<String, bool> permissions)
  onSave;
  final bool allowModerator;

  const _AdminPermissionsSheet({
    required this.member,
    required this.onSave,
    required this.allowModerator,
  });

  @override
  State<_AdminPermissionsSheet> createState() => _AdminPermissionsSheetState();
}

class _AdminPermissionsSheetState extends State<_AdminPermissionsSheet> {
  late MemberRole _role;
  late Map<String, bool> _permissions;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _role = widget.member.role;
    _permissions = Map<String, bool>.from(
      widget.member.effectiveAdminPermissions,
    );
  }

  void _setRole(MemberRole role) {
    setState(() {
      _role = role;
      _permissions = AdminPermission.defaultsForRole(role);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_role, Map<String, bool>.from(_permissions));
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final roleValues = <MemberRole>[
      MemberRole.admin,
      if (widget.allowModerator) MemberRole.moderator,
      MemberRole.member,
    ];
    final roleLabels = [
      for (final role in roleValues)
        switch (role) {
          MemberRole.admin => 'Admin',
          MemberRole.moderator => 'Moderator',
          MemberRole.member => 'Member',
        },
    ];
    final selectedRoleIndex = roleValues
        .indexOf(_role)
        .clamp(0, roleValues.length - 1);

    return GlassBottomSheetFrame(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 680),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlassSheetGrabber(),
                GlassSheetHeader(
                  icon: Icons.admin_panel_settings_outlined,
                  title:
                      '@${widget.member.user?.username ?? widget.member.userId}',
                  subtitle: 'Role & permissions',
                  onClose: _saving ? null : () => Navigator.pop(context),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GlassSegmentedControl(
                    segments: roleLabels,
                    selectedIndex: selectedRoleIndex,
                    onSegmentSelected: _saving
                        ? (_) {}
                        : (index) => _setRole(roleValues[index]),
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final permission in AdminPermission.values)
                        GlassListTile(
                          leading: Icon(_iconFor(permission)),
                          title: Text(
                            _permissionLabels[permission]!,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          trailing: GlassSwitch(
                            value: _permissions[permission] ?? false,
                            onChanged: (value) {
                              if (!_saving && _role != MemberRole.member) {
                                setState(
                                  () => _permissions[permission] = value,
                                );
                              }
                            },
                            activeColor: Theme.of(context).colorScheme.primary,
                            enableHaptics: true,
                          ),
                          onTap: _saving || _role == MemberRole.member
                              ? null
                              : () => setState(
                                  () => _permissions[permission] =
                                      !(_permissions[permission] ?? false),
                                ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      GlassButtonWidget(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const Spacer(),
                      GlassButtonWidget.icon(
                        onPressed: _saving ? null : _save,
                        color: scheme.primary,
                        icon: _saving
                            ? const GlassProgressIndicator.circular(
                                size: 16,
                                strokeWidth: 2,
                              )
                            : const Icon(Icons.check_rounded),
                        label: const Text('Save'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _iconFor(String permission) => switch (permission) {
  AdminPermission.manageInfo => Icons.badge_outlined,
  AdminPermission.manageSettings => Icons.tune_rounded,
  AdminPermission.manageEncryption => Icons.lock_outline_rounded,
  AdminPermission.manageTopics => Icons.forum_outlined,
  AdminPermission.manageMembers => Icons.group_outlined,
  AdminPermission.manageRoles => Icons.admin_panel_settings_outlined,
  AdminPermission.manageInvites => Icons.link_rounded,
  AdminPermission.approveJoinRequests => Icons.how_to_reg_outlined,
  AdminPermission.managePins => Icons.push_pin_outlined,
  AdminPermission.deleteMessages => Icons.delete_sweep_outlined,
  AdminPermission.manageModeration => Icons.shield_outlined,
  AdminPermission.postMessages => Icons.campaign_outlined,
  _ => Icons.check_circle_outline,
};
