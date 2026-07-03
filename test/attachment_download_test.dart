import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/attachment_service.dart';

class _FakeApi extends Fake implements ApiService {}

void main() {
  // Regression: _downloadBytes returned the body-reading future WITHOUT
  // awaiting it inside try/finally, so `httpClient.close(force: true)` in the
  // finally aborted the connection while the body was still streaming and
  // every real-network download failed with "Connection closed while
  // receiving data" (voice notes showed as unplayable). The delayed chunks
  // below keep the body in flight long past the return statement.
  test('download reads the full body when it arrives in delayed chunks', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    final chunk = List<int>.filled(64 * 1024, 7);
    const chunkCount = 8;
    server.listen((req) async {
      req.response.headers.contentType = ContentType.binary;
      req.response.contentLength = chunk.length * chunkCount;
      for (var i = 0; i < chunkCount; i++) {
        req.response.add(chunk);
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await req.response.close();
    });

    final svc = AttachmentService(_FakeApi());
    final bytes = await svc.debugDownloadBytes(
      'http://${server.address.address}:${server.port}/blob',
    );

    expect(bytes.length, chunk.length * chunkCount);
    expect(bytes.every((b) => b == 7), isTrue);
  });
}
