import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/chat_provider.dart';

void main() {
  test(
      'sender hydration refreshes missing bubble colour from conversation members',
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

    ChatProvider.hydrateMessageSenderFromConversationForTesting(msg, conv);

    expect(msg.sender?.bubbleColor, 0xFF26323A);
  });
}
