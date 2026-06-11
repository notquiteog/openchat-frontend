/// On-device "local AI" subject segmentation (background removal) for the
/// sticker creator.
///
/// Implemented as pure-Dart ONNX inference (u2netp through ONNX Runtime FFI)
/// so it works identically on Android/iOS/Linux/macOS/Windows — see
/// segmentation_service_native.dart. The model is downloaded on first use
/// (~4.7 MB, progress on [SegmentationService.downloadProgress]); web gets a
/// graceful "unsupported" stub because ORT needs dart:ffi.
///
/// The pure preprocess/postprocess pipeline (and [SegmentationException]) is
/// re-exported from segmentation_pipeline.dart.
library;

export 'segmentation_pipeline.dart';
export 'segmentation_service_unsupported.dart'
    if (dart.library.io) 'segmentation_service_native.dart';
