import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var callBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var callForegroundChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    configureCallForegroundChannel()
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
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
        result(FlutterMethodNotImplemented)
      }
    }
    callForegroundChannel = channel
  }

  private func startCallBackgrounding(isVideo: Bool) -> Bool {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: isVideo ? .videoChat : .voiceChat,
        options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
      )
      try session.setActive(true)
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
}
