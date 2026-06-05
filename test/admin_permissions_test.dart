import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';

ConversationMember _member({
  required MemberRole role,
  Map<String, bool>? permissions,
}) {
  return ConversationMember(
    conversationId: 'conv-1',
    userId: 'user-1',
    role: role,
    adminPermissions: permissions,
    joinedAt: DateTime.utc(2026, 6, 1),
  );
}

void main() {
  test('admins default to every permission', () {
    final member = _member(role: MemberRole.admin);

    expect(member.hasPermission(AdminPermission.manageEncryption), isTrue);
    expect(member.hasPermission(AdminPermission.manageRoles), isTrue);
    expect(member.hasPermission(AdminPermission.postMessages), isTrue);
  });

  test('moderators keep legacy moderation permissions', () {
    final member = _member(role: MemberRole.moderator);

    expect(member.hasPermission(AdminPermission.manageModeration), isTrue);
    expect(member.hasPermission(AdminPermission.deleteMessages), isTrue);
    expect(member.hasPermission(AdminPermission.managePins), isTrue);
    expect(member.hasPermission(AdminPermission.manageRoles), isFalse);
  });

  test('explicit permissions override defaults', () {
    final member = _member(
      role: MemberRole.admin,
      permissions: {AdminPermission.manageEncryption: false},
    );

    expect(member.hasPermission(AdminPermission.manageEncryption), isFalse);
    expect(member.hasPermission(AdminPermission.manageInfo), isTrue);
  });
}
