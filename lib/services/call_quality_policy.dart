import 'dart:math' as math;

import 'package:flutter_webrtc/flutter_webrtc.dart';

class CallQualityPolicy {
  final bool dataSaver;
  final bool forceAudioOnly;
  final int maxVideoBitrate;
  final int maxFramerate;
  final int maxHeight;

  const CallQualityPolicy({
    required this.dataSaver,
    required this.forceAudioOnly,
    required this.maxVideoBitrate,
    required this.maxFramerate,
    required this.maxHeight,
  });

  const CallQualityPolicy.normal({bool forceAudioOnly = false})
    : this(
        dataSaver: false,
        forceAudioOnly: forceAudioOnly,
        maxVideoBitrate: 1200000,
        maxFramerate: 30,
        maxHeight: 720,
      );

  const CallQualityPolicy.dataSaver({bool forceAudioOnly = false})
    : this(
        dataSaver: true,
        forceAudioOnly: forceAudioOnly,
        maxVideoBitrate: 300000,
        maxFramerate: 20,
        maxHeight: 360,
      );
}

RTCRtpParameters applyVideoSenderCaps(
  RTCRtpParameters params,
  CallQualityPolicy policy,
) {
  if (!policy.dataSaver) return params;
  final encodings = params.encodings;
  if (encodings == null || encodings.isEmpty) {
    params.encodings = [RTCRtpEncoding()];
  }
  final scale = math.max(1.0, 720 / math.max(1, policy.maxHeight));
  for (final encoding in params.encodings!) {
    encoding.maxBitrate = policy.maxVideoBitrate;
    encoding.maxFramerate = policy.maxFramerate;
    encoding.scaleResolutionDownBy = scale;
  }
  params.degradationPreference = RTCDegradationPreference.MAINTAIN_FRAMERATE;
  return params;
}
