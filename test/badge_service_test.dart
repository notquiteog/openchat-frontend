import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/services/badge_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Conversation _conv(String id, int unread) => Conversation(
  id: id,
  type: ConversationType.dm,
  createdAt: DateTime.utc(2026, 1, 1),
  createdBy: 'user-a',
  unreadCount: unread,
);

void main() {
  group('computeUnreadBadgeTotal', () {
    test('sums unread across conversations', () {
      final total = computeUnreadBadgeTotal(
        conversations: [_conv('a', 2), _conv('b', 0), _conv('c', 5)],
        archivedIds: const {},
        isMuted: (_) => false,
      );
      expect(total, 7);
    });

    test('excludes muted conversations', () {
      final total = computeUnreadBadgeTotal(
        conversations: [_conv('a', 2), _conv('b', 9)],
        archivedIds: const {},
        isMuted: (id) => id == 'b',
      );
      expect(total, 2);
    });

    test('excludes archived conversations', () {
      final total = computeUnreadBadgeTotal(
        conversations: [_conv('a', 2), _conv('b', 9)],
        archivedIds: const {'b'},
        isMuted: (_) => false,
      );
      expect(total, 2);
    });

    test('all quiet means zero (badge cleared)', () {
      final total = computeUnreadBadgeTotal(
        conversations: [_conv('a', 0)],
        archivedIds: const {},
        isMuted: (_) => false,
      );
      expect(total, 0);
    });
  });

  group('background increment bookkeeping', () {
    test(
      'builds on the last foreground total across multiple pushes',
      () async {
        SharedPreferences.setMockInitialValues({
          badgeLastTotalPrefsKey: 3,
          badgeBackgroundIncrementPrefsKey: 0,
        });

        await BadgeService.incrementFromBackground();
        await BadgeService.incrementFromBackground();

        final prefs = await SharedPreferences.getInstance();
        // Two background messages on top of 3 known unread.
        expect(prefs.getInt(badgeBackgroundIncrementPrefsKey), 2);
        expect(prefs.getInt(badgeLastTotalPrefsKey), 3);
      },
    );

    test(
      'republish resets background bumps even when the total is unchanged',
      () async {
        SharedPreferences.setMockInitialValues({});
        final applied = <int>[];
        final service = BadgeService(
          applyPlatformBadge: (count) async => applied.add(count),
        );

        // No chat attached: authoritative total is 0.
        await service.debugPublish();
        expect(applied, [0]);

        // Unchanged total and clean bookkeeping — the early return holds.
        await service.debugPublish();
        expect(applied, [0]);

        // FCM isolate bumps the platform badge behind the service's back; the
        // next publish must reapply the authoritative badge and reset the
        // bookkeeping even though the in-memory total never moved.
        await BadgeService.incrementFromBackground();
        await service.debugPublish();
        expect(applied, [0, 0]);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(badgeBackgroundIncrementPrefsKey), 0);
        expect(prefs.getInt(badgeLastTotalPrefsKey), 0);
      },
    );
  });
}
