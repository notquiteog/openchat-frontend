/// On-device voice-note transcription.
///
/// Whisper-tiny (int8) running through sherpa-onnx FFI, fully offline: the
/// model (~90 MB across three files) is downloaded once on demand into
/// `<app support dir>/asr/whisper-tiny/` — never bundled, never any audio or
/// text leaving the device. Voice notes are AAC `.m4a`; they are decoded to
/// 16 kHz mono PCM via ffmpeg-kit on Android/iOS/macOS and a system `ffmpeg`
/// binary on Linux/Windows. Web gets a graceful "unsupported" stub (FFI).
library;

export 'transcription_service_unsupported.dart'
    if (dart.library.io) 'transcription_service_native.dart';
