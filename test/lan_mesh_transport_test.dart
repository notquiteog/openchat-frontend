import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/mesh/lan_mesh_transport.dart';
import 'package:openchat/services/mesh/mesh_frames.dart';
import 'package:openchat/services/mesh/mesh_session.dart';

/// Loopback TCP — no network hardware needed, runs in CI.
Future<(LanMeshLink, LanMeshLink)> loopbackPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = server.first;
  final client = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
  );
  final pair = (LanMeshLink(await accepted), LanMeshLink(client));
  await server.close();
  return pair;
}

void main() {
  group('beacon codec', () {
    test('round-trips and rejects garbage', () {
      final parsed = parseLanBeacon(lanBeaconPayload('abc123', 4567));
      expect(parsed, isNotNull);
      expect(parsed!.tag, 'abc123');
      expect(parsed.port, 4567);
      expect(parseLanBeacon('not-ours'), isNull);
      expect(parseLanBeacon('oc-mesh:v1:tag'), isNull);
      expect(parseLanBeacon('oc-mesh:v1:tag:notaport'), isNull);
      expect(parseLanBeacon('oc-mesh:v1:tag:99999'), isNull);
      expect(parseLanBeacon('oc-mesh:v1::123'), isNull);
    });
  });

  group('LanMeshLink', () {
    test('an unauthenticated link with no frames is idle-reaped', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final raw = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final link = LanMeshLink(
        await accepted,
        unauthIdleTimeout: const Duration(milliseconds: 35),
      );
      await server.close();
      addTearDown(() async {
        raw.destroy();
        await link.close();
      });

      await expectLater(link.inboundChunks, emitsDone);
    });

    test('markAuthenticated disarms the pre-auth idle reaper', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final raw = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final link = LanMeshLink(
        await accepted,
        unauthIdleTimeout: const Duration(milliseconds: 35),
      );
      await server.close();
      var closed = false;
      link.inboundChunks.listen(null, onDone: () => closed = true);
      addTearDown(() async {
        raw.destroy();
        await link.close();
      });

      link.markAuthenticated();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(closed, isFalse);
      expect(link.isAuthenticated, isTrue);
    });

    test('frames cross intact, including coalesced/split TCP reads', () async {
      final (a, b) = await loopbackPair();
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      final received = <Uint8List>[];
      final reassembler = MeshReassembler();
      b.inboundChunks.listen((chunk) {
        final frame = reassembler.addChunk(chunk);
        if (frame != null) received.add(frame);
      });
      final small = encodeMeshFrame(meshFrameHello, Uint8List.fromList([1]));
      final big = encodeMeshFrame(
        meshFrameMessage,
        Uint8List.fromList(List.generate(100 * 1024, (i) => i % 251)),
      );
      // Back-to-back sends exercise record framing across TCP coalescing.
      await a.sendFrame(small);
      await a.sendFrame(big);
      await a.sendFrame(small);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, hasLength(3));
      expect(received[0], small);
      expect(decodeMeshFrame(received[1]).payload.length, 100 * 1024);
      expect(received[2], small);
    });

    test(
      'a full identity handshake + message runs over loopback TCP',
      () async {
        final (linkA, linkB) = await loopbackPair();
        addTearDown(() async {
          await linkA.close();
          await linkB.close();
        });
        MeshSession sessionOn(LanMeshLink link, String fp, int seed) {
          final session = MeshSession(
            selfFingerprint: fp,
            selfPublicKeyArmored: 'KEY:$fp',
            selfDisplayName: 'user-$fp',
            sign: (data) async => 'SIG|$data|$fp',
            verify: (data, signature, publicKey) async =>
                signature == 'SIG|$data|${publicKey.substring(4)}',
            fingerprintOf: (publicKey) async => publicKey.substring(4),
            sendFrame: (type, payload) =>
                link.sendFrame(encodeMeshFrame(type, payload)),
            random: Random(seed),
          );
          final reassembler = MeshReassembler();
          link.inboundChunks.listen((chunk) {
            final frame = reassembler.addChunk(chunk);
            if (frame != null) {
              unawaited(session.handleFrame(decodeMeshFrame(frame)));
            }
          });
          return session;
        }

        final a = sessionOn(linkA, 'AAAA', 1);
        final b = sessionOn(linkB, 'BBBB', 2);
        final received = <Map<String, dynamic>>[];
        b.messages.listen(received.add);

        await a.start();
        await b.start();
        // Real sockets: poll briefly instead of a fixed sleep.
        for (var i = 0; i < 100 && !(a.authenticated && b.authenticated); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(a.authenticated, isTrue, reason: a.failure ?? '');
        expect(b.authenticated, isTrue, reason: b.failure ?? '');
        expect(a.peer!.fingerprint, 'BBBB');

        await a.sendMessageEnvelope({'conversation_id': 'c1', 'n': 1});
        for (var i = 0; i < 100 && received.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(received, [
          {'conversation_id': 'c1', 'n': 1},
        ]);
      },
    );

    test(
      'an oversized record header kills the link instead of buffering it',
      () async {
        // Raw client socket so we can forge a hostile length prefix —
        // LanMeshLink.sendChunk always writes truthful ones.
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final accepted = server.first;
        final raw = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        final link = LanMeshLink(await accepted);
        await server.close();
        addTearDown(() async {
          raw.destroy();
          await link.close();
        });
        final done = expectLater(link.inboundChunks, emitsDone);
        final hostile = ByteData(4)..setUint32(0, 1 << 30, Endian.little);
        raw.add(hostile.buffer.asUint8List());
        await raw.flush();
        await done; // link dropped the connection without buffering a GiB
      },
    );
  });

  group('LanMeshTransport hardening', () {
    test('bounds dialed tag memory with LRU eviction', () {
      final transport = LanMeshTransport(maxDialedTags: 3);

      expect(transport.debugRememberDialedTag('a'), isTrue);
      expect(transport.debugRememberDialedTag('b'), isTrue);
      expect(transport.debugRememberDialedTag('c'), isTrue);
      expect(transport.debugRememberDialedTag('b'), isFalse);
      expect(transport.debugRememberDialedTag('d'), isTrue);
      expect(transport.debugDialedTagCount, 3);
      expect(
        transport.debugRememberDialedTag('a'),
        isTrue,
        reason: 'the oldest tag should have been evicted',
      );
      expect(transport.debugDialedTagCount, 3);
    });

    test('rate-limits beacon-triggered dials per source address', () {
      final transport = LanMeshTransport(
        maxDialsPerWindow: 2,
        dialRateWindow: const Duration(seconds: 1),
      );

      expect(transport.debugAllowDialFrom('192.0.2.10'), isTrue);
      expect(transport.debugAllowDialFrom('192.0.2.10'), isTrue);
      expect(transport.debugAllowDialFrom('192.0.2.10'), isFalse);
      expect(
        transport.debugAllowDialFrom('192.0.2.11'),
        isTrue,
        reason: 'a different source address gets its own budget',
      );
    });

    test(
      'caps unauthenticated inbound links and frees a slot on auth',
      () async {
        final transport = LanMeshTransport(
          maxConcurrentUnauthInbound: 1,
          unauthIdleTimeout: const Duration(seconds: 5),
        );
        final links = <LanMeshLink>[];
        final sub = transport.newLinks.listen(links.add);
        final rawSockets = <Socket>[];
        addTearDown(() async {
          for (final socket in rawSockets) {
            socket.destroy();
          }
          await sub.cancel();
          await transport.stop();
        });

        await transport.start(sessionTag: 'z');
        final port = transport.debugTcpPort!;

        rawSockets.add(
          await Socket.connect(InternetAddress.loopbackIPv4, port),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(links, hasLength(1));
        expect(transport.debugUnauthLinkCount, 1);

        rawSockets.add(
          await Socket.connect(InternetAddress.loopbackIPv4, port),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(links, hasLength(1));
        expect(transport.debugUnauthLinkCount, 1);

        links.single.markAuthenticated();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(transport.debugUnauthLinkCount, 0);

        rawSockets.add(
          await Socket.connect(InternetAddress.loopbackIPv4, port),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(links, hasLength(2));
        expect(transport.debugUnauthLinkCount, 1);
      },
    );
  });
}
