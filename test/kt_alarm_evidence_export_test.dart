import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/screens/settings/trust_center_screen.dart';

void main() {
  test('KT alarm evidence export decodes nested evidence JSON', () {
    final exported = formatKtAlarmEvidenceForExport({
      'reason': 'rollback',
      'at': '2026-06-15T12:00:00Z',
      'evidence': jsonEncode({
        'cached_size': 5,
        'server_size': 3,
        'root_hash': 'abc',
      }),
    });

    final decoded = jsonDecode(exported) as Map<String, dynamic>;
    expect(decoded['openchat_kt_alarm'], 1);
    expect(decoded['reason'], 'rollback');
    expect(decoded['at'], '2026-06-15T12:00:00Z');
    expect(decoded['evidence'], isA<Map<String, dynamic>>());
    expect((decoded['evidence'] as Map<String, dynamic>)['server_size'], 3);
    expect(exported.contains(r'\"server_size\"'), isFalse);
  });
}
