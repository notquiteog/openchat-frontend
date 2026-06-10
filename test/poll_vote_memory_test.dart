import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/services/secure_storage_service.dart';

// Refetched poll payloads don't echo the viewer's own votes (anonymous polls
// can't, by design) — the marked bubble survives chat re-entry through the
// device-local vote memory in secure storage, merged back at render time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('poll vote selections survive a storage round trip', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = SecureStorageService();

    expect(await storage.getPollVoteSelections('poll-1'), isEmpty);

    await storage.savePollVoteSelections('poll-1', ['opt-a', 'opt-b']);
    expect(await storage.getPollVoteSelections('poll-1'), ['opt-a', 'opt-b']);

    // Retracting (or revoting to nothing) clears the mark.
    await storage.savePollVoteSelections('poll-1', []);
    expect(await storage.getPollVoteSelections('poll-1'), isEmpty);

    // Other polls are unaffected.
    expect(await storage.getPollVoteSelections('poll-2'), isEmpty);
  });

  test('locally remembered votes mark the refetched poll', () {
    // A refetched poll: the server reports tallies but no voter_option_ids.
    final refetched = Poll.fromJson({
      'id': 'poll-1',
      'question': 'Where to?',
      'type': 'regular',
      'options': [
        {'id': 'opt-a', 'text': 'Beach', 'option_index': 0, 'voter_count': 2},
        {'id': 'opt-b', 'text': 'Hills', 'option_index': 1, 'voter_count': 1},
      ],
    });
    expect(refetched.voterOptionIds, isEmpty);
    expect(refetched.isSelected('opt-a'), isFalse);

    // The render-time merge restores the device-local memory.
    final merged = refetched.copyWith(voterOptionIds: ['opt-a']);
    expect(merged.isSelected('opt-a'), isTrue);
    expect(merged.isSelected('opt-b'), isFalse);
  });
}
