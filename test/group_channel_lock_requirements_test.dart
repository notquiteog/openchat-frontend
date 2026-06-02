import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/screens/chat/chat_screen.dart';
import 'package:openchat/screens/channels/channel_action_policy.dart';
import 'package:openchat/services/app_access_gate.dart';
import 'package:openchat/widgets/conversation_info_panel.dart';

Conversation _conversation({
  ConversationType type = ConversationType.group,
  String? avatarUrl = '/media/group.webp',
  String? description = 'Planning and release coordination',
  DateTime? archivedAt,
}) {
  return Conversation(
    id: 'conv-1',
    type: type,
    name: type == ConversationType.channel ? 'Announcements' : 'Release Crew',
    description: description,
    avatarUrl: avatarUrl,
    archivedAt: archivedAt,
    createdAt: DateTime.utc(2026, 6, 1),
    createdBy: 'owner-1',
    members: [
      ConversationMember(
        conversationId: 'conv-1',
        userId: 'owner-1',
        role: MemberRole.admin,
        joinedAt: DateTime.utc(2026, 6, 1),
      ),
      ConversationMember(
        conversationId: 'conv-1',
        userId: 'member-2',
        role: MemberRole.member,
        joinedAt: DateTime.utc(2026, 6, 1),
      ),
    ],
  );
}

void main() {
  group('Biometric and app lock gates', () {
    test('ios plist declares face id usage for private key export', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();

      expect(plist, contains('<key>NSFaceIDUsageDescription</key>'));
      expect(plist, contains('private key'));
    });

    test('biometric key unlock does not lock the whole app', () {
      final decision = AppAccessGateDecision.resolve(
        authenticated: true,
        appLockEnabled: false,
        appLocked: false,
        biometricKeyExportEnabled: true,
      );

      expect(decision, AppAccessGateDecision.showApp);
    });

    test('app lock is the only setting that gates the whole app', () {
      final decision = AppAccessGateDecision.resolve(
        authenticated: true,
        appLockEnabled: true,
        appLocked: true,
        biometricKeyExportEnabled: false,
      );

      expect(decision, AppAccessGateDecision.showAppLock);
    });
  });

  group('Conversation info surface', () {
    testWidgets('group info shows avatar, description, and member count',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationInfoPanel(
              conversation: _conversation(),
              currentUserId: 'owner-1',
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('conversation-info-avatar')), findsOneWidget);
      expect(find.text('Release Crew'), findsOneWidget);
      expect(find.text('Planning and release coordination'), findsOneWidget);
      expect(find.text('2 members'), findsOneWidget);
    });
  });

  group('Channel action placement', () {
    test('crowded actions move to moderation and settings menus', () {
      final placement = ChannelActionPolicy.actionsFor(
        channel: _conversation(type: ConversationType.channel),
        isAdmin: true,
        isPremium: true,
        canManageLifecycle: true,
        isSubscribed: true,
      );

      expect(placement.topBar, contains(ChannelTopBarAction.moderation));
      expect(placement.topBar, contains(ChannelTopBarAction.settings));
      expect(placement.topBar, isNot(contains(ChannelTopBarAction.archive)));
      expect(placement.topBar, isNot(contains(ChannelTopBarAction.autoDelete)));
      expect(placement.topBar, isNot(contains(ChannelTopBarAction.encryption)));
      expect(
          placement.moderationMenu, contains(ChannelModerationAction.archive));
      expect(
          placement.settingsMenu, contains(ChannelSettingsAction.appearance));
      expect(placement.settingsMenu,
          contains(ChannelSettingsAction.deleteOwnMessages));
      expect(
          placement.settingsMenu, contains(ChannelSettingsAction.autoDelete));
      expect(
          placement.settingsMenu, contains(ChannelSettingsAction.encryption));
    });

    test('channel subscribers get chat appearance for their bubble color', () {
      final placement = ChannelActionPolicy.actionsFor(
        channel: _conversation(type: ConversationType.channel),
        isAdmin: false,
        isPremium: false,
        canManageLifecycle: false,
        isSubscribed: true,
      );

      expect(placement.topBar, contains(ChannelTopBarAction.settings));
      expect(placement.settingsMenu, [
        ChannelSettingsAction.appearance,
        ChannelSettingsAction.deleteOwnMessages,
      ]);
    });

    test('archived channel exposes unarchive and delete in moderation menu',
        () {
      final placement = ChannelActionPolicy.actionsFor(
        channel: _conversation(
          type: ConversationType.channel,
          archivedAt: DateTime.utc(2026, 6, 1),
        ),
        isAdmin: true,
        isPremium: false,
        canManageLifecycle: true,
        isSubscribed: false,
      );

      expect(
        placement.moderationMenu,
        containsAll([
          ChannelModerationAction.unarchive,
          ChannelModerationAction.delete,
        ]),
      );
      expect(placement.topBar, isNot(contains(ChannelTopBarAction.delete)));
    });

    test('channel owner does not get an unsubscribe action', () {
      final placement = ChannelActionPolicy.actionsFor(
        channel: _conversation(type: ConversationType.channel),
        isAdmin: true,
        isPremium: false,
        canManageLifecycle: true,
        isSubscribed: true,
      );

      expect(
          placement.topBar, isNot(contains(ChannelTopBarAction.unsubscribe)));
      expect(placement.topBar, isNot(contains(ChannelTopBarAction.subscribe)));
    });
  });

  group('Conversation exit labels', () {
    test('group participants see leave language instead of delete language',
        () {
      expect(
        conversationExitMenuLabel(
          _conversation(),
          currentUserId: 'member-2',
        ),
        'Leave group',
      );
    });

    test('group owner with another admin still sees leave language', () {
      final group = _conversation().copyWith(members: [
        ConversationMember(
          conversationId: 'conv-1',
          userId: 'owner-1',
          role: MemberRole.admin,
          joinedAt: DateTime.utc(2026, 6, 1),
        ),
        ConversationMember(
          conversationId: 'conv-1',
          userId: 'admin-2',
          role: MemberRole.admin,
          joinedAt: DateTime.utc(2026, 6, 1),
        ),
      ]);

      expect(
        conversationExitMenuLabel(group, currentUserId: 'owner-1'),
        'Leave group',
      );
    });
  });
}
