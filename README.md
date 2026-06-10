# OpenChat

Open-source, end-to-end encrypted messenger with OpenPGP (RFC 4880).
Flutter client for Windows, Linux, macOS, Android, and iOS.

## Features

- **E2E encryption** — all messages encrypted and decrypted on-device. ML-KEM-1024 + X448 (post-quantum hybrid) is the default; Curve25519, RSA-4096, and other hybrid post-quantum composite key types are also available. The private key never leaves the device.
- **Multi-recipient group messages** — anonymous `pgp_envelope_v1` slots with sender identity and message type kept inside the encrypted signed body; the server never sees plaintext, sender IDs, or recipient fingerprints.
- **MLS for large encrypted rooms** — OpenMLS using the X-Wing hybrid post-quantum ciphersuite (`mls256XwingChacha20Poly1305Sha256Ed25519`) by default. Switching a group or channel to MLS raises the recipient-count cap and removes the PGP multi-recipient limit.
- **Channels** — Telegram-style public broadcast channels with subscribe/unsubscribe, admin-only posting mode, and channel-wide moderation controls.
- **Audio & video calls** — WebRTC P2P with ICE/STUN/TURN, including group SFU calls for larger rooms.
- **Stories** — ephemeral 24-hour posts visible to your followers, with pull-to-reveal from the home screen.
- **File & media attachments** — AES-256-GCM client-side encryption before upload; the server stores only ciphertext.
- **Invite links** — shareable invite links for groups and channels.
- **Stickers & custom emoji** — sticker packs with per-pack privacy controls; custom emoji in messages.
- **Live location** — opt-in real-time location sharing in conversations.
- **PGP key rotation** — rotate your keypair at any time; old messages stay readable via the previous key.
- **MLS key rotation** — ratcheting forward secrecy; the server validates shape but never holds MLS signing or encryption keys.
- **Public key cache** — SQLite cache with 24 h TTL to minimise round-trips for large groups.
- **Key expiry handling** — expired imported keys trigger a home-screen banner with rotation instructions; other clients gracefully exclude the expired participant rather than failing the whole group.
- **Key fingerprint verification** — verify contacts out-of-band by scanning a QR code from the profile screen.
- **Biometric private-key export** — `local_auth` can require fingerprint / face authentication before private-key export.
- **App lock** — optional biometric lock on every resume.
- **System tray** (desktop) — minimize to tray, unread badge, quick-compose.
- **Push notifications** — optional Firebase FCM (Android/iOS). Defaults off with a privacy warning.
- **Background WebSocket** — persistent WS connection when backgrounded (Android foreground service). Mutually exclusive with push notifications.
- **Offline outbox** — messages queued locally and delivered automatically when connectivity is restored.
- **Message search** — full-text search over the local message cache.
- **Mini apps** — lightweight in-chat web views.
- **Bots** — first-class encrypted bot support; see the [Bot API docs](https://github.com/notquiteog/openchat-bot-sdk).
- **Premium tier** — optional server-side premium with Stripe, Bitcoin, and Monero payment support. The free tier is fully functional; premium is purely additive.

## Platforms

Windows · Linux · macOS · Android · iOS (64-bit only)

## Prerequisites

- **Flutter 3.44+** — install via [flutter.dev](https://flutter.dev/docs/get-started/install)
- **Android**: Android Studio with the Android NDK; arm64-v8a only
- **iOS / macOS**: Xcode 15+, Apple Developer account
- **Windows**: Visual Studio 2022 with the "Desktop development with C++" workload
- **Linux**: distro-specific packages listed in the [Linux](#linux) section below

## Getting started

### 1. Clone

```sh
git clone https://github.com/notquiteog/openchat-frontend.git
cd openchat-frontend
flutter pub get
```

### 2. Point at your server

Server coordinates are injected at build time via `--dart-define`. Defaults to `localhost:8080` (HTTP) for local development.

```sh
# Production
flutter run \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true
```

### 3. Run (local dev)

```sh
flutter run   # uses localhost:8080 by default
```

---

## Building releases

### Android

```sh
# Debug APK
flutter build apk \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true

# Signed release APK
flutter build apk --release \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true

# Android App Bundle (for Google Play)
flutter build appbundle --release \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true
```

To sign a release APK, create a keystore (first time only):

```sh
keytool -genkey -v -keystore ~/openchat.jks \
        -alias openchat -keyalg RSA -keysize 4096 -validity 10000
```

Then create `android/key.properties`:

```properties
storePassword=<keystore-password>
keyPassword=<key-password>
keyAlias=openchat
storeFile=/home/you/openchat.jks
```

`android/app/build.gradle` picks this up automatically for release builds.

Output: `build/app/outputs/flutter-apk/app-release.apk`
and `build/app/outputs/bundle/release/app-release.aab`

---

### iOS

Requires Xcode 15+ and an Apple Developer account.

```sh
# App Store build
flutter build ios --release \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true
```

Then open `build/ios/archive/Runner.xcarchive` in Xcode Organizer to export an IPA for App Store, TestFlight, or ad-hoc distribution.

For automated IPA export, add an `ExportOptions.plist` and run:

```sh
xcodebuild -exportArchive \
  -archivePath build/ios/archive/Runner.xcarchive \
  -exportPath build/ios/ipa \
  -exportOptionsPlist ExportOptions.plist
```

Output: `build/ios/ipa/openchat.ipa`

---

### Linux

Install build dependencies first (see [Linux dependencies](#linux-dependencies) below), then:

```sh
flutter build linux --release \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true
```

Output: `build/linux/x64/release/bundle/`

To package as a tarball:

```sh
VERSION=$(grep '^version:' pubspec.yaml | cut -d' ' -f2 | cut -d'+' -f1)
tar -czf openchat-${VERSION}-linux-x86_64.tar.gz \
  -C build/linux/x64/release bundle
```

---

### Windows

```powershell
flutter build windows --release `
  --dart-define=OPENCHAT_HOST=chat.example.com `
  --dart-define=OPENCHAT_PORT=443 `
  --dart-define=OPENCHAT_HTTPS=true
```

Output: `build\windows\x64\runner\Release\`

To create a distributable ZIP:

```powershell
$version = (Select-String 'version:' pubspec.yaml).Line.Split(' ')[1].Split('+')[0]
Compress-Archive build\windows\x64\runner\Release\* `
  openchat-$version-windows-x64.zip
```

For code signing with an EV certificate or MSIX packaging, pass the certificate thumbprint to `signtool` or use the MSIX packaging tools from the Visual Studio installer.

---

### macOS

```sh
flutter build macos --release \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true
```

Output: `build/macos/Build/Products/Release/openchat.app`

For distribution outside the App Store, notarize the app:

```sh
# Codesign
codesign --deep --force --options runtime \
  --sign "Developer ID Application: Your Name (XXXXXXXXXX)" \
  build/macos/Build/Products/Release/openchat.app

# Create a ZIP for notarization submission
ditto -c -k --keepParent \
  build/macos/Build/Products/Release/openchat.app \
  openchat.zip

# Submit
xcrun notarytool submit openchat.zip \
  --apple-id you@example.com \
  --team-id XXXXXXXXXX \
  --wait

# Staple the ticket
xcrun stapler staple build/macos/Build/Products/Release/openchat.app
```

---

## Push notifications (optional)

Push notifications require a Firebase project. Release CI injects `android/app/google-services.json` and `lib/firebase_options.dart` from GitHub secrets; iOS builds should inject `ios/Runner/GoogleService-Info.plist` the same way. To enable push locally:

1. Create a Firebase project at <https://console.firebase.google.com/>
2. Add Android (`com.openchat.openchat`) and iOS (`com.openchat.openchat`) apps
3. Run `flutterfire configure` — it overwrites the three platform config files with real values
4. On the server, set `FIREBASE_SERVICE_ACCOUNT_JSON` so the server can send FCM messages

> **Security:** Once you have real Firebase credentials, keep the platform config files out of git and inject them from secrets instead.

---

## Linux dependencies

### Build dependencies

```sh
# Debian / Ubuntu
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev libstdc++-12-dev liblzma-dev libsecret-1-dev \
  libx11-dev libxi-dev libunwind-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libmpv-dev

# Fedora
sudo dnf install -y clang cmake ninja-build pkgconf-pkg-config \
  gtk3-devel xz-devel libsecret-devel libX11-devel libXi-devel \
  libunwind-devel gstreamer1-devel gstreamer1-plugins-base-devel

# Arch / CachyOS
sudo pacman -S --needed base-devel clang cmake ninja pkgconf gtk3 xz \
  libsecret libx11 libxi libunwind gstreamer gst-plugins-base
```

For Debian packages and Flatpak bundles on Debian/Ubuntu builders, also install:

```sh
sudo apt install -y desktop-file-utils dpkg-dev flatpak flatpak-builder
```

### WSL (Windows Subsystem for Linux)

See [docs/wsl-flutter-setup.md](../docs/wsl-flutter-setup.md) for step-by-step Flutter + Android SDK setup on WSL Ubuntu 24.04, including the native Linux Flutter install needed to avoid Windows line-ending issues.

---

## Linux Secret Service / keyring

OpenChat stores session tokens and PGP private keys through `flutter_secure_storage`, which uses libsecret on Linux. The desktop session must provide a working Secret Service backend — usually GNOME Keyring or KWallet.

On GNOME this is automatic. On newer or mixed desktop environments such as COSMIC on Arch/CachyOS, verify the following if the app logs `libsecret_error: KeyringLocked`.

**Runtime / keyring packages:**

```sh
# Debian / Ubuntu
sudo apt install -y gnome-keyring libsecret-1-0 libsecret-tools seahorse \
  xdg-desktop-portal xdg-desktop-portal-gtk

# Fedora
sudo dnf install -y gnome-keyring libsecret libsecret-tools seahorse \
  xdg-desktop-portal xdg-desktop-portal-gtk

# Arch / CachyOS
sudo pacman -S --needed gnome-keyring libsecret seahorse \
  xdg-desktop-portal xdg-desktop-portal-gtk

# COSMIC only, if available in your repositories
sudo pacman -S --needed xdg-desktop-portal-cosmic
```

OpenChat ships a helper script for diagnosing and fixing keyring setup:

```sh
./tool/configure_linux_keyring.sh --check   # report only
./tool/configure_linux_keyring.sh --apply   # prompt before each host-level change
```

`--check` only reports problems. `--apply` can: install the optional COSMIC portal package if available; write the user-level Secret portal preference; add `pam_gnome_keyring.so` auth/session hooks to the greeter PAM service; repair a missing default Secret Service alias; clear stale GNOME Keyring item paths by restarting the user Secret Service; and warn about or remove the `nopasswdlogin` group that prevents login-time keyring unlock. Pass `--cosmic-portal` to manage COSMIC portal config on a system where COSMIC was not auto-detected.

**Verify the default alias:**

```sh
busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
  org.freedesktop.Secret.Service ReadAlias s default
```

**Login-time unlock** requires GNOME Keyring hooks in the display manager's PAM service:

```text
auth       optional     pam_gnome_keyring.so
session    optional     pam_gnome_keyring.so auto_start
```

**Fix a missing default alias** (if the `Default` collection exists but the alias isn't set):

```sh
busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
  org.freedesktop.Secret.Service SetAlias so default \
  /org/freedesktop/secrets/collection/Default
```

**Flatpak on COSMIC** — prefer GNOME Keyring for the Secret portal by placing this at `~/.config/xdg-desktop-portal/cosmic-portals.conf`:

```ini
[preferred]
default=cosmic;gtk;
org.freedesktop.impl.portal.Secret=gnome-keyring;
```

OpenChat treats a locked keyring during startup as recoverable and starts logged out rather than crashing. The auth screens show a `System keyring unavailable` warning and avoid saving keys or tokens until the desktop session exposes an unlocked Secret Service.

---

## Architecture

| Layer | Details |
|-------|---------|
| State management | `provider` |
| Crypto | `openpgp` (ProtonMail/go-crypto via FFI), `openmls`, `cryptography` (AES-256-GCM for attachments) |
| Secure storage | `flutter_secure_storage` → Keychain / Android Keystore / Windows Credential Manager / Linux Secret Service |
| Local DB | `drift` + `sqflite` (SQLite) — message cache, key cache, call history |
| Calls | `flutter_webrtc` P2P + `livekit_client` for SFU group calls |
| Media | `just_audio` + `just_audio_media_kit`, `video_player` |
| Notifications | `flutter_local_notifications` + optional Firebase FCM |
| Location | `geolocator` |
| QR codes | `pretty_qr_code`, `mobile_scanner` |
| UI | `liquid_glass_widgets`, Material 3, custom shaders |

---

## Contributing

Pull requests are welcome. Please open an issue first for any significant feature or breaking change.

- Dart SDK ≥ 3.12, Flutter ≥ 3.44
- Run `dart analyze` and `flutter test` before submitting
- Format with `dart format .`

---

## License

MIT
