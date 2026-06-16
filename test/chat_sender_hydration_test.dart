import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/chat_provider.dart';

void main() {
  test(
    'sender hydration refreshes missing bubble color from conversation members',
    () {
      final msg = Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        senderId: 'user-2',
        type: MessageType.text,
        encryptedPayload: 'cipher',
        signature: '',
        createdAt: DateTime.utc(2026, 1, 1),
        sender: User(
          id: 'user-2',
          username: 'alice',
          publicKey: 'pub',
          keyFingerprint: 'fingerprint',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
      final conv = Conversation(
        id: 'conv-1',
        type: ConversationType.group,
        name: 'Release',
        createdAt: DateTime.utc(2026, 1, 1),
        createdBy: 'user-1',
        members: [
          ConversationMember(
            conversationId: 'conv-1',
            userId: 'user-2',
            role: MemberRole.member,
            joinedAt: DateTime.utc(2026, 1, 1),
            user: User(
              id: 'user-2',
              username: 'alice',
              publicKey: 'pub',
              keyFingerprint: 'fingerprint',
              bubbleColor: 0xFF26323A,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ),
        ],
      );

      ChatProvider.hydrateMessageSenderFromConversation(msg, conv);

      expect(msg.sender?.bubbleColor, 0xFF26323A);
    },
  );

  test('sender hydration refreshes changed bubble color on past messages', () {
    final msg = Message(
      id: 'msg-1',
      conversationId: 'conv-1',
      senderId: 'user-2',
      type: MessageType.text,
      encryptedPayload: 'cipher',
      signature: '',
      createdAt: DateTime.utc(2026, 1, 1),
      sender: User(
        id: 'user-2',
        username: 'alice',
        publicKey: 'pub',
        keyFingerprint: 'fingerprint',
        bubbleColor: 0xFF26323A,
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    final conv = Conversation(
      id: 'conv-1',
      type: ConversationType.group,
      name: 'Release',
      createdAt: DateTime.utc(2026, 1, 1),
      createdBy: 'user-1',
      members: [
        ConversationMember(
          conversationId: 'conv-1',
          userId: 'user-2',
          role: MemberRole.member,
          joinedAt: DateTime.utc(2026, 1, 1),
          user: User(
            id: 'user-2',
            username: 'alice',
            publicKey: 'pub',
            keyFingerprint: 'fingerprint',
            bubbleColor: 0xFF42A5F5,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ),
      ],
    );

    ChatProvider.hydrateMessageSenderFromConversation(msg, conv);

    expect(msg.sender?.bubbleColor, 0xFF42A5F5);
  });

  test('silent conversation refresh ignores identical server snapshots', () {
    final createdAt = DateTime.utc(2026, 6, 1);
    final lastMessage = Message(
      id: 'msg-1',
      conversationId: 'conv-1',
      senderId: 'user-2',
      type: MessageType.text,
      encryptedPayload: 'cipher',
      signature: '',
      createdAt: createdAt,
    );
    final current = Conversation(
      id: 'conv-1',
      type: ConversationType.dm,
      createdAt: createdAt,
      createdBy: 'user-1',
      lastMessage: lastMessage,
      unreadCount: 1,
    );
    final fresh = Conversation(
      id: 'conv-1',
      type: ConversationType.dm,
      createdAt: createdAt,
      createdBy: 'user-1',
      lastMessage: lastMessage,
      unreadCount: 1,
    );

    expect(
      ChatProvider.hasConversationListChanges(
        current: <String, Conversation>{'conv-1': current},
        fresh: <Conversation>[fresh],
      ),
      isFalse,
    );
  });
}
