# iOS screen sharing — Broadcast Upload Extension setup

The Dart/app side is done: `_supportsScreenShare` now returns `true` on iOS, so the
**Share** button appears in a video call, and `startScreenShare()` calls
`navigator.mediaDevices.getDisplayMedia(...)`, which on iOS makes flutter_webrtc present
the **system broadcast picker** (`RPSystemBroadcastPickerView`).

That picker is empty / the share does nothing until a **Broadcast Upload Extension** is
added to the Xcode project and connected to the app over an **App Group**. Those steps
require Xcode on macOS (a new target, capabilities, signing, embedding, build) and could
not be done in the Linux dev environment — follow this runbook on the Mac.

flutter_webrtc already ships the *app-side* receiver (`FlutterBroadcastScreenCapturer`,
`FlutterSocketConnectionFrameReader`). You only add the *extension-side* uploader.

---

## 1. Pick an App Group id
Use one id for both targets, e.g.:

    group.com.openchat.openchat

## 2. Add the App Group capability to the Runner app
- Xcode → Runner target → Signing & Capabilities → **+ Capability → App Groups** → add
  `group.com.openchat.openchat`.
- This writes it into `ios/Runner/Runner.entitlements`.

## 3. Add the Broadcast Upload Extension target
- Xcode → File → New → Target → **Broadcast Upload Extension**.
  - Product name: `BroadcastExtension` (bundle id becomes
    `com.openchat.openchat.BroadcastExtension`).
  - **Uncheck** "Include UI Extension".
  - When prompted, do **not** activate the scheme.
- Add the **App Groups** capability to this new target too, same id
  `group.com.openchat.openchat`.

## 4. Runner `Info.plist` — tell flutter_webrtc about the group + extension
Add these keys to `ios/Runner/Info.plist` (the exact key names flutter_webrtc reads —
see `FlutterBroadcastScreenCapturer.m`: `RTCAppGroupIdentifier`,
`RTCScreenSharingExtension`):

```xml
<key>RTCAppGroupIdentifier</key>
<string>group.com.openchat.openchat</string>
<key>RTCScreenSharingExtension</key>
<string>com.openchat.openchat.BroadcastExtension</string>
```

## 5. Extension `Info.plist`
Xcode generates one; make sure it has the App Group id available to the extension. Add:

```xml
<key>RTCAppGroupIdentifier</key>
<string>group.com.openchat.openchat</string>
```
(The `NSExtension` / `NSExtensionPointIdentifier = com.apple.broadcast-services-upload`
and `RPBroadcastProcessMode = RPBroadcastProcessModeSampleBuffer` entries are added by the
Xcode template — leave them.)

## 6. Extension source (`SampleHandler` + socket uploader)
The extension captures `CMSampleBuffer`s and ships them to the app over a Unix-domain
socket in the App-Group container. Use flutter_webrtc's **canonical, maintained**
extension files (do not hand-roll the socket): copy these four into the extension target
from the official guide — https://github.com/flutter-webrtc/flutter-webrtc/wiki/iOS-Screen-Sharing

- `SampleHandler.swift`
- `SocketConnection.swift`
- `SampleUploader.swift`
- `DarwinNotificationCenter.swift`

`SampleHandler` reads the App Group id (`RTCAppGroupIdentifier`) from the extension's
Info.plist and opens the socket named `rtc_SSFD` (`kRTCScreensharingSocketFD`) in the
group container — these must match the app side, which is why steps 4/5 use the same id.

> Keep the extension's **Deployment Target ≤ Runner's**, and add the same Swift version.
> The extension has a tight memory budget (~50 MB) — the flutter_webrtc uploader already
> downscales; don't add heavy work in `SampleHandler`.

## 7. Build & run on a **real device**
- Screen sharing does **not** work in the iOS Simulator — use a physical device.
- Select the Runner scheme (not the extension), run, start a video call, tap **Share**,
  pick **OpenChat** (the extension) in the system sheet, **Start Broadcast**.

## 8. Stopping
`stopScreenShare()` already calls `replaceTrack` back to the camera and disposes the
screen stream; on iOS the user can also stop from the status bar / picker. No extra Dart
needed.

---

### Recap of what's already in the repo
- `lib/services/call_service.dart` → `_supportsScreenShare` includes `TargetPlatform.iOS`.
- `startScreenShare()` already skips the Android-only foreground-service block on iOS and
  calls `getDisplayMedia`, which triggers the broadcast picker.

### What still must be done in Xcode (this runbook, on macOS)
- App Group on both targets, the Broadcast Upload Extension target, the two Info.plist
  keys, the four extension Swift files, signing for the extension, and a device build.
