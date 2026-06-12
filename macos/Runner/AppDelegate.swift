import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Tray app: the window normally never closes (window_manager intercepts
    // via setPreventClose), but if tray startup failed or timed out the close
    // button would otherwise quit the whole app. Quit only via the tray menu.
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
