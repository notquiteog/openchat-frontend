import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/sfu_call_reactions.dart';

void main() {
  test('reaction packets round-trip through the data channel codec', () {
    final packet = SfuCallReactionCodec.decode(
      SfuCallReactionCodec.encodeReaction('👍'),
    );

    expect(packet, isNotNull);
    expect(packet!.kind, SfuCallPacketKind.reaction);
    expect(packet.emoji, '👍');
    expect(packet.handRaised, isNull);
  });

  test('raise-hand packets round-trip through the data channel codec', () {
    final raised = SfuCallReactionCodec.decode(
      SfuCallReactionCodec.encodeRaiseHand(true),
    );
    final lowered = SfuCallReactionCodec.decode(
      SfuCallReactionCodec.encodeRaiseHand(false),
    );

    expect(raised?.kind, SfuCallPacketKind.raiseHand);
    expect(raised?.handRaised, isTrue);
    expect(lowered?.kind, SfuCallPacketKind.raiseHand);
    expect(lowered?.handRaised, isFalse);
  });

  test(
    'codec rejects malformed, oversized, unknown, and off-allowlist input',
    () {
      expect(SfuCallReactionCodec.decode(const []), isNull);
      expect(SfuCallReactionCodec.decode(utf8.encode('{')), isNull);
      expect(SfuCallReactionCodec.decode(List<int>.filled(513, 65)), isNull);
      expect(
        SfuCallReactionCodec.decode(utf8.encode(jsonEncode({'t': 'x'}))),
        isNull,
      );
      expect(
        SfuCallReactionCodec.decode(
          utf8.encode(jsonEncode({'t': 'r', 'e': '🧪'})),
        ),
        isNull,
      );
      expect(
        () => SfuCallReactionCodec.encodeReaction('🧪'),
        throwsArgumentError,
      );
    },
  );
}
