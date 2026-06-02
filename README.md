# OpenChat — Frontend

Open-source, end-to-end encrypted messenger with OpenPGP. Flutter client for the [OpenChat](https://github.com/notquiteog/openchat) backend.

## Features

- **E2E encryption** — all messages encrypted/decrypted on-device using OpenPGP. ML-KEM-1024 + X448 is the default; Curve25519, RSA-4096, and other post-quantum composite key types are available. Private key never leaves the device.
- **Multi-recipient group messages** — OpenChat stores one signed+encrypted PGP ciphertext per recipient inside a compact envelope.
- **Channels** — Telegram-style public broadcast channels.
- **Audio & video calls** — WebRTC P2P, signaled via the backend WebSocket relay.
- **File & media attachments** — AES-256-GCM client-side encryption before upload.
- **PGP key rotation** — rotate your keypair at any time; old messages stay readable.
- **Public key cache** — SQLite cache with 24 h TTL to minimise round-trips for large groups.
- **Biometric private-key export** — local_auth can require fingerprint / face authentication before private-key export.
- **App lock** — optional biometric lock on every resume.
- **Push notifications** — optional Firebase FCM (Android/iOS). Defaults off with a privacy warning.
- **Background WebSocket** — keeps a persistent WS connection when the app is backgrounded (Android foreground service). Mutually exclusive with push notifications.

## Platforms

Windows · Linux · macOS · Android · iOS (64-bit only)

## Getting started

### 1. Clone

```sh
git clone https://github.com/notquiteog/openchat-frontend.git
cd openchat-frontend
flutter pub get
```

### 2. Point at your backend

Server coordinates are injected at build time via `--dart-define`. Defaults to `localhost:8080` (HTTP) for local development.

```sh
# Production example
flutter run \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true
```

### 3. Run (local dev)

```sh
flutter run          # uses localhost:8080 by default
```

## Push notifications (optional)

Push notifications require a Firebase project. The files `android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist`, and `lib/firebase_options.dart` are committed as placeholder templates so the project compiles without Firebase. To enable push:

1. Create a Firebase project at <https://console.firebase.google.com/>
2. Add Android (`com.openchat.openchat`) and iOS (`com.openchat.openchat`) apps
3. Run `flutterfire configure` — it overwrites the three files above with real values
4. On the server, set `FIREBASE_SERVICE_ACCOUNT_JSON` so the backend can send FCM messages

> **Security:** Once you have real Firebase credentials, add the three config files to your local `.gitignore` so you don't accidentally commit them.

## Building releases

```sh
# Android APK
flutter build apk --release \
  --dart-define=OPENCHAT_HOST=chat.example.com \
  --dart-define=OPENCHAT_PORT=443 \
  --dart-define=OPENCHAT_HTTPS=true

# Android App Bundle
flutter build appbundle --release ...

# Windows
flutter build windows --release ...

# Linux
flutter build linux --release ...
```

## Linux Secret Service / keyring

Linux secure storage uses `flutter_secure_storage` through libsecret. That means OpenChat needs a working Secret Service backend, usually GNOME Keyring or KWallet. If the keyring is locked or the default collection alias is missing, startup may log `libsecret_error: KeyringLocked`; OpenChat treats locked startup reads as recoverable, but login persistence and key writes still require an unlocked keyring.

On Arch/CachyOS with COSMIC, install and wire GNOME Keyring because COSMIC does not provide its own Secret Service backend:

```sh
sudo pacman -S gnome-keyring libsecret seahorse xdg-desktop-portal
```

The greeter's PAM service should include:

```text
auth       optional     pam_gnome_keyring.so
session    optional     pam_gnome_keyring.so auto_start
```

If `busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service ReadAlias s default` returns no collection while `/org/freedesktop/secrets/collection/Default` exists, set the default alias:

```sh
busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
  org.freedesktop.Secret.Service SetAlias so default \
  /org/freedesktop/secrets/collection/Default
```

For Flatpak on COSMIC, prefer GNOME Keyring for the Secret portal with `~/.config/xdg-desktop-portal/cosmic-portals.conf`:

```ini
[preferred]
default=cosmic;gtk;
org.freedesktop.impl.portal.Secret=gnome-keyring;
```

## Architecture

| Layer | Details |
|---|---|
| State management | `provider` |
| Crypto | `openpgp`, `cryptography` (AES-256-GCM for attachments) |
| Secure storage | `flutter_secure_storage` -> Keychain / Android Keystore / Windows Credential Manager / Linux Secret Service |
| Local DB | `sqflite` + `drift` (SQLite) — message cache + key cache |
| Calls | `flutter_webrtc` P2P, ICE via STUN/TURN |
| Notifications | `flutter_local_notifications` + optional Firebase FCM |

## Backend

See [notquiteog/openchat](https://github.com/notquiteog/openchat) — Go + PostgreSQL + Redis + RustFS/S3-compatible object storage.

## License

MIT
