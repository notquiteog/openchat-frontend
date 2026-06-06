import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'call_service.dart';

abstract class CallAudioController {
  Future<void> update({CallState? state, bool incoming = false});
  Future<void> stop();
  void dispose();
}

/// Plays the looping call tones: `ringing.mp3` while a call is ringing (incoming
/// awaiting answer, or outgoing awaiting pickup) and `connecting.mp3` while media
/// is negotiating. Driven by [CallProvider] from the call state; a no-op once the
/// call connects or ends. Tolerant of platforms without audio output.
class CallAudio implements CallAudioController {
  final AudioPlayer _player = AudioPlayer();
  Future<void> _pending = Future<void>.value();
  int _op = 0;
  String? _current; // 'ringing' | 'connecting' | null

  @override
  Future<void> stop() async {
    await _enqueue(null);
  }

  /// Update the tone to match the call. [incoming] is an unanswered incoming
  /// call; otherwise [state] is the active session's state.
  @override
  Future<void> update({CallState? state, bool incoming = false}) {
    if (incoming) return _enqueue('ringing');
    return _enqueue(switch (state) {
      CallState.calling || CallState.ringing => 'ringing',
      CallState.connecting => 'connecting',
      _ => null,
    });
  }

  Future<void> _enqueue(String? tone) {
    final op = ++_op;
    _pending = _pending.then((_) => _apply(op: op, tone: tone));
    return _pending;
  }

  Future<void> _apply({required int op, required String? tone}) async {
    if (op != _op) return;
    if (tone == null) {
      // Check both _current and the player's live state so that a silently-
      // failing stop() (e.g. PipeWire on Linux not completing cleanly) can
      // still be retried on the next _enqueue(null) call.
      if (_current == null && !_player.playing) return;
      try {
        await _player.stop();
      } catch (_) {}
      _current = null;
      return;
    }
    if (_current == tone) return;
    _current = tone;
    try {
      await _player.stop();
      if (op != _op || _current != tone) return;
      await _player.setLoopMode(LoopMode.one);
      if (op != _op || _current != tone) return;
      await _player.setAsset('assets/sounds/$tone.mp3');
      if (op != _op || _current != tone) return;
      await _player.play();
    } catch (_) {
      // No audio device / unsupported — fail quietly, the call still works.
    }
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
  }
}
