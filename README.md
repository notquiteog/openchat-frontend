# OpenChat — Frontend

Open-source, end-to-end encrypted messenger with OpenPGP. Flutter client for the [OpenChat](https://github.com/notquiteog/openchat) backend.

## Features

- **E2E encryption** — all messages encrypted/decrypted on-device using OpenPGP. ML-KEM-1024 + X448 is the default; Curve25519, RSA-4096, and other post-quantum composite key types are available. Private key never leaves the device.
- **Multi-recipient group messages** — OpenChat stores anonymous PGP envelope slots, with sender identity and message type kept inside the encrypted signed body.
- **MLS for large encrypted rooms** — OpenMLS uses the X-Wing hybrid post-quantum ciphersuite by default.
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

Push notifications require a Firebase project. Release CI injects `android/app/google-services.json` and `lib/firebase_options.dart` from GitHub secrets; iOS Firebase builds should inject `ios/Runner/GoogleService-Info.plist` the same way. To enable push:

1. Create a Firebase project at <https://console.firebase.google.com/>
2. Add Android (`com.openchat.openchat`) and iOS (`com.openchat.openchat`) apps
3. Run `flutterfire configure` — it overwrites the three files above with real values
4. On the server, set `FIREBASE_SERVICE_ACCOUNT_JSON` so the backend can send FCM messages

> **Security:** Once you have real Firebase credentials, keep the platform config files out of git and inject them from secrets.

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

## Linux packages

For source builds:

```sh
# Debian / Ubuntu
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev libstdc++-12-dev liblzma-dev libsecret-1-dev \
  libx11-dev libxi-dev libunwind-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev

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

## Linux Secret Service / keyring

Linux secure storage uses `flutter_secure_storage` through libsecret. That means OpenChat needs a working Secret Service backend, usually GNOME Keyring or KWallet. If the keyring is locked or the default collection alias is missing, startup may log `libsecret_error: KeyringLocked`; OpenChat treats locked startup reads as recoverable. Current Linux builds also run a small secure-storage preflight before sign-in and account creation; if the host keyring is locked or unavailable, the auth screens show a `System keyring unavailable` warning and avoid saving keys or tokens until the desktop session exposes an unlocked Secret Service.

On Arch/CachyOS with COSMIC, install and wire GNOME Keyring because COSMIC does not provide its own Secret Service backend:

Runtime/keyring packages:

```sh
# Debian / Ubuntu
sudo apt install -y gnome-keyring libsecret-1-0 libsecret-tools seahorse xdg-desktop-portal xdg-desktop-portal-gtk

# Fedora
sudo dnf install -y gnome-keyring libsecret libsecret-tools seahorse xdg-desktop-portal xdg-desktop-portal-gtk

# Arch / CachyOS
sudo pacman -S --needed gnome-keyring libsecret seahorse xdg-desktop-portal xdg-desktop-portal-gtk

# COSMIC only, if the package exists in your enabled repositories
sudo pacman -S --needed xdg-desktop-portal-cosmic
```

OpenChat ships a Linux helper for this:

```sh
./tool/configure_linux_keyring.sh --check
./tool/configure_linux_keyring.sh --apply
```

The helper is conservative: `--check` only reports problems, while `--apply` prompts before host-level changes. On non-COSMIC desktops it leaves COSMIC portal config untouched. On COSMIC/CachyOS it can additionally install the optional COSMIC portal package when available, write the user-level Secret portal preference, add backed-up `pam_gnome_keyring.so` auth/session hooks to the greeter PAM service, repair a missing default Secret Service alias, clear stale GNOME Keyring item paths by restarting the user Secret Service, and warn about or remove the `nopasswdlogin` group that prevents login-time keyring unlock. Pass `--cosmic-portal` if you need to manage COSMIC portal config on a system where COSMIC was not auto-detected.

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
