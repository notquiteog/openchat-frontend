import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/smp_service.dart';

void main() {
  group('SMP', () {
    test('matches when both sides hold the same secret', () {
      final secret = smpSecret(
        myFingerprint: 'AAAA',
        theirFingerprint: 'BBBB',
        answer: 'hunter2',
      );
      // Responder derives the same secret (fingerprints sorted internally).
      final secretB = smpSecret(
        myFingerprint: 'BBBB',
        theirFingerprint: 'AAAA',
        answer: 'hunter2',
      );
      expect(secret, equals(secretB));

      final alice = SmpInitiator(secret);
      final bob = SmpResponder(secretB);

      final m1 = alice.init();
      final m2 = bob.step2(m1);
      final m3 = alice.step3(m2);
      final m4 = bob.step4(m3);
      final aliceOk = alice.finish(m4);

      expect(bob.matched, isTrue, reason: 'responder should match');
      expect(aliceOk, isTrue, reason: 'initiator should match');
    });

    test('does not match when secrets differ', () {
      final secretA = smpSecret(
        myFingerprint: 'AAAA',
        theirFingerprint: 'BBBB',
        answer: 'correct',
      );
      final secretB = smpSecret(
        myFingerprint: 'BBBB',
        theirFingerprint: 'AAAA',
        answer: 'WRONG',
      );

      final alice = SmpInitiator(secretA);
      final bob = SmpResponder(secretB);

      final m1 = alice.init();
      final m2 = bob.step2(m1);
      final m3 = alice.step3(m2);
      final m4 = bob.step4(m3);
      final aliceOk = alice.finish(m4);

      expect(bob.matched, isFalse, reason: 'responder must not match');
      expect(aliceOk, isFalse, reason: 'initiator must not match');
    });

    test('fingerprint binding changes the secret (MITM resistance)', () {
      final honest = smpSecret(
        myFingerprint: 'AAAA',
        theirFingerprint: 'BBBB',
        answer: 'shared',
      );
      // A MITM with a different key (different fingerprint) derives a different
      // secret even with the same answer, so SMP would fail against them.
      final mitm = smpSecret(
        myFingerprint: 'AAAA',
        theirFingerprint: 'CCCC',
        answer: 'shared',
      );
      expect(honest, isNot(equals(mitm)));
    });

    test('rejects tampered peer values', () {
      final secret = smpSecret(
        myFingerprint: 'AAAA',
        theirFingerprint: 'BBBB',
        answer: 'x',
      );
      final alice = SmpInitiator(secret);
      final bob = SmpResponder(secret);

      final m1 = alice.init();
      // Tamper with a knowledge proof before Bob verifies it.
      final tampered = Map<String, String>.from(m1)..['g2a'] = '2';
      expect(() => bob.step2(tampered), throwsA(isA<SmpException>()));
    });
  });
}
