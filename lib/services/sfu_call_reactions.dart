import 'dart:convert';

const sfuCallReactionTopic = 'call-reaction';
const sfuCallReactionMaxBytes = 512;
const sfuCallReactionEmojiAllowlist = <String>[
  '👍',
  '❤️',
  '😂',
  '🎉',
  '👏',
  '😮',
  '🔥',
  '🙏',
];

enum SfuCallPacketKind { reaction, raiseHand }

class SfuCallPacket {
  final SfuCallPacketKind kind;
  final String? emoji;
  final bool? handRaised;

  const SfuCallPacket._({required this.kind, this.emoji, this.handRaised});

  const SfuCallPacket.reaction(String emoji)
    : this._(kind: SfuCallPacketKind.reaction, emoji: emoji);

  const SfuCallPacket.raiseHand(bool value)
    : this._(kind: SfuCallPacketKind.raiseHand, handRaised: value);
}

class SfuCallReaction {
  final String id;
  final String identity;
  final String emoji;

  const SfuCallReaction({
    required this.id,
    required this.identity,
    required this.emoji,
  });
}

class SfuCallReactionCodec {
  const SfuCallReactionCodec._();

  static List<int> encodeReaction(String emoji) {
    if (!sfuCallReactionEmojiAllowlist.contains(emoji)) {
      throw ArgumentError.value(emoji, 'emoji', 'not allowed');
    }
    return utf8.encode(jsonEncode({'t': 'r', 'e': emoji}));
  }

  static List<int> encodeRaiseHand(bool value) {
    return utf8.encode(jsonEncode({'t': 'h', 'v': value}));
  }

  static SfuCallPacket? decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > sfuCallReactionMaxBytes) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      final type = decoded['t'];
      if (type == 'r') {
        final emoji = decoded['e'];
        if (emoji is! String ||
            !sfuCallReactionEmojiAllowlist.contains(emoji)) {
          return null;
        }
        return SfuCallPacket.reaction(emoji);
      }
      if (type == 'h') {
        final value = decoded['v'];
        if (value is! bool) return null;
        return SfuCallPacket.raiseHand(value);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
