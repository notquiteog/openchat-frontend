import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:openchat/services/call_quality_policy.dart';

void main() {
  test('normal policy leaves sender parameters unchanged', () {
    final params = RTCRtpParameters(encodings: [RTCRtpEncoding()]);

    applyVideoSenderCaps(params, const CallQualityPolicy.normal());

    expect(params.encodings!.single.maxBitrate, isNull);
    expect(params.encodings!.single.maxFramerate, isNull);
    expect(params.encodings!.single.scaleResolutionDownBy, 1.0);
    expect(params.degradationPreference, isNull);
  });

  test('data-saver policy caps bitrate, frame rate, and resolution scale', () {
    final params = RTCRtpParameters(encodings: [RTCRtpEncoding()]);

    applyVideoSenderCaps(params, const CallQualityPolicy.dataSaver());

    final encoding = params.encodings!.single;
    expect(encoding.maxBitrate, 300000);
    expect(encoding.maxFramerate, 20);
    expect(encoding.scaleResolutionDownBy, 2.0);
    expect(
      params.degradationPreference,
      RTCDegradationPreference.MAINTAIN_FRAMERATE,
    );
  });

  test('data-saver policy creates an encoding if the sender has none', () {
    final params = RTCRtpParameters();

    applyVideoSenderCaps(params, const CallQualityPolicy.dataSaver());

    expect(params.encodings, hasLength(1));
    expect(params.encodings!.single.maxBitrate, 300000);
  });
}
