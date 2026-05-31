import 'package:audioplayers/audioplayers.dart';
import 'call_service.dart';

/// Plays the looping call tones: `ringing.mp3` while a call is ringing (incoming
/// awaiting answer, or outgoing awaiting pickup) and `connecting.mp3` while media
/// is negotiating. Driven by [CallProvider] from the call state; a no-op once the
/// call connects or ends. Tolerant of platforms without audio output.
class CallAudio {
  final AudioPlayer _player = AudioPlayer();
  String? _current; // 'ringing' | 'connecting' | null

  Future<void> _play(String tone) async {
    if (_current == tone) return;
    _current = tone;
    try {
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('sounds/$tone.mp3'));
    } catch (_) {
      // No audio device / unsupported — fail quietly, the call still works.
    }
  }

  Future<void> stop() async {
    if (_current == null) return;
    _current = null;
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// Update the tone to match the call. [incoming] is an unanswered incoming
  /// call; otherwise [state] is the active session's state.
  void update({CallState? state, bool incoming = false}) {
    if (incoming) {
      _play('ringing');
      return;
    }
    switch (state) {
      case CallState.calling:
      case CallState.ringing:
        _play('ringing');
      case CallState.connecting:
        _play('connecting');
      default:
        stop();
    }
  }

  void dispose() {
    _player.dispose();
  }
}
