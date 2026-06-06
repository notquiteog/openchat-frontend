import AVFoundation
@preconcurrency import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var callBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var callForegroundChannel: FlutterMethodChannel?
  private var callControlsChannel: FlutterMethodChannel?
  private var selectedCallAudioRoute: CallAudioRoute = .speaker
  private var currentCallIsVideo = false
  private var microphoneMuted = false

  private enum CallAudioRoute: String, Equatable {
    case speaker
    case earpiece
    case bluetooth
    case wiredHeadset = "wired-headset"
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    configureCallForegroundChannel()
    configureCallControlsChannel()
    return launched
  }

  nonisolated func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func configureCallForegroundChannel() {
    guard callForegroundChannel == nil,
          let registrar = registrar(forPlugin: "OpenChatCallForeground") else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "openchat/call_foreground",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "start":
        let args = call.arguments as? [String: Any]
        let isVideo = args?["isVideo"] as? Bool ?? false
        result(self?.startCallBackgrounding(isVideo: isVideo) ?? false)
      case "stop":
        self?.stopCallBackgrounding()
        result(nil)
      case "takePendingActions":
        result([])
      default:
        result(Self.methodNotImplementedError(for: call.method))
      }
    }
    callForegroundChannel = channel
  }

  private func startCallBackgrounding(isVideo: Bool) -> Bool {
    do {
      currentCallIsVideo = isVideo
      let routeApplied = try configureAudioSession(
        isVideo: isVideo,
        route: selectedCallAudioRoute
      )
      if !routeApplied && selectedCallAudioRoute != .speaker {
        selectedCallAudioRoute = .speaker
        _ = try configureAudioSession(isVideo: isVideo, route: .speaker)
      }
      UIApplication.shared.isIdleTimerDisabled = true
      beginCallBackgroundTask()
      return true
    } catch {
      return false
    }
  }

  private func stopCallBackgrounding() {
    UIApplication.shared.isIdleTimerDisabled = false
    endCallBackgroundTask()
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func beginCallBackgroundTask() {
    endCallBackgroundTask()
    callBackgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "OpenChatActiveCall"
    ) { [weak self] in
      self?.endCallBackgroundTask()
    }
  }

  private func endCallBackgroundTask() {
    guard callBackgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(callBackgroundTask)
    callBackgroundTask = .invalid
  }

  private func configureCallControlsChannel() {
    guard callControlsChannel == nil,
          let registrar = registrar(forPlugin: "OpenChatCallControls") else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "openchat/call_controls",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "selectAudioOutput":
        let args = call.arguments as? [String: Any]
        let deviceId = args?["deviceId"] as? String ?? ""
        let isVideo = args?["isVideo"] as? Bool ?? false
        result(self?.selectAudioOutput(deviceId, isVideo: isVideo) ?? false)
      case "setMicrophoneMuted":
        let args = call.arguments as? [String: Any]
        let muted = args?["muted"] as? Bool ?? false
        result(self?.setMicrophoneMuted(muted) ?? false)
      case "clearAudioOutput":
        self?.clearAudioOutput()
        result(nil)
      default:
        result(Self.methodNotImplementedError(for: call.method))
      }
    }
    callControlsChannel = channel
  }

  private nonisolated static func methodNotImplementedError(
    for method: String
  ) -> FlutterError {
    FlutterError(
      code: "method_not_implemented",
      message: "Method not implemented: \(method)",
      details: nil
    )
  }

  private func selectAudioOutput(_ deviceId: String, isVideo: Bool) -> Bool {
    guard let route = CallAudioRoute(rawValue: deviceId) else {
      return false
    }
    selectedCallAudioRoute = route
    currentCallIsVideo = isVideo
    do {
      return try configureAudioSession(isVideo: isVideo, route: route)
    } catch {
      return false
    }
  }

  private func setMicrophoneMuted(_ muted: Bool) -> Bool {
    microphoneMuted = muted
    _ = applyMicrophoneMuteIfPossible()
    return true
  }

  @discardableResult
  private func configureAudioSession(
    isVideo: Bool,
    route: CallAudioRoute
  ) throws -> Bool {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: audioSessionMode(isVideo: isVideo, route: route),
      options: audioSessionOptions(for: route)
    )
    try session.setActive(true)
    _ = applyMicrophoneMuteIfPossible()

    try? session.setPreferredInput(nil)
    try session.overrideOutputAudioPort(.none)

    switch route {
    case .speaker:
      try session.overrideOutputAudioPort(.speaker)
      return true
    case .earpiece:
      if let builtInMic = preferredInput(
        for: [.builtInMic],
        in: session
      ) {
        try? session.setPreferredInput(builtInMic)
      }
      return true
    case .bluetooth:
      guard let bluetoothInput = preferredInput(
        for: [.bluetoothHFP, .bluetoothLE],
        in: session
      ) else {
        return routeMatches(.bluetooth, in: session)
      }
      try session.setPreferredInput(bluetoothInput)
      return true
    case .wiredHeadset:
      guard let headsetMic = preferredInput(
        for: [.headsetMic],
        in: session
      ) else {
        return routeMatches(.wiredHeadset, in: session)
      }
      try session.setPreferredInput(headsetMic)
      return true
    }
  }

  private func applyMicrophoneMuteIfPossible() -> Bool {
    let session = AVAudioSession.sharedInstance()
    guard session.isInputGainSettable else { return false }
    do {
      try session.setInputGain(microphoneMuted ? 0.0 : 1.0)
      return true
    } catch {
      return false
    }
  }

  private func clearAudioOutput() {
    selectedCallAudioRoute = .speaker
    let session = AVAudioSession.sharedInstance()
    try? session.setPreferredInput(nil)
    try? session.overrideOutputAudioPort(.none)
  }

  private func audioSessionMode(
    isVideo: Bool,
    route: CallAudioRoute
  ) -> AVAudioSession.Mode {
    route == .earpiece ? .voiceChat : (isVideo ? .videoChat : .voiceChat)
  }

  private func audioSessionOptions(
    for route: CallAudioRoute
  ) -> AVAudioSession.CategoryOptions {
    switch route {
    case .speaker:
      return [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
    case .bluetooth:
      return [.allowBluetooth, .allowBluetoothA2DP]
    case .earpiece, .wiredHeadset:
      return []
    }
  }

  private func preferredInput(
    for portTypes: [AVAudioSession.Port],
    in session: AVAudioSession
  ) -> AVAudioSessionPortDescription? {
    let inputs = session.availableInputs ?? []
    return inputs.first { port in
      portTypes.contains(port.portType)
    }
  }

  private func routeMatches(
    _ route: CallAudioRoute,
    in session: AVAudioSession
  ) -> Bool {
    let outputs = session.currentRoute.outputs.map(\.portType)
    switch route {
    case .speaker:
      return outputs.contains(.builtInSpeaker)
    case .earpiece:
      return outputs.contains(.builtInReceiver)
    case .bluetooth:
      return outputs.contains(.bluetoothHFP)
        || outputs.contains(.bluetoothA2DP)
        || outputs.contains(.bluetoothLE)
    case .wiredHeadset:
      return outputs.contains(.headphones)
    }
  }
}
