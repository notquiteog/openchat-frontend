# OpenChat — Frontend

Open-source, end-to-end encrypted messenger with OpenPGP. Flutter client for the [OpenChat](https://github.com/notquiteog/openchat) backend.

## Features

- **E2E encryption** — all messages encrypted/decrypted on-device using OpenPGP (Curve25519 by default, RSA-4096 optional). Private key never leaves the device.
- **Multi-recipient group messages** — one PGP message per group message with a per-member PKESK block.
- **Channels** — Telegram-style public broadcast channels.
- **Audio & video calls** — WebRTC P2P, signaled via the backend WebSocket relay.
- **File & media attachments** — AES-256-GCM client-side encryption before upload.
- **PGP key rotation** — rotate your keypair at any time; old messages stay readable.
- **Public key cache** — SQLite cache with 24 h TTL to minimise round-trips for large groups.
- **Biometric key unlock** — local_auth gates private-key access so the key session locks on app background.
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

## Architecture

| Layer | Details |
|---|---|
| State management | `provider` |
| Crypto | `dart_pg` (OpenPGP), `cryptography` (AES-256-GCM for attachments) |
| Secure storage | `flutter_secure_storage` → Keychain / Keystore / Credential Manager |
| Local DB | `drift` (SQLite) — message cache + key cache |
| Calls | `flutter_webrtc` P2P, ICE via STUN/TURN |
| Notifications | `flutter_local_notifications` + optional Firebase FCM |

## Backend

See [notquiteog/openchat](https://github.com/notquiteog/openchat) — Go + PostgreSQL + Redis + MinIO.

## License

MIT
