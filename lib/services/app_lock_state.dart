import 'package:flutter/foundation.dart';

/// Whether the app lock (PIN/biometric gate) is currently engaged.
///
/// The home shell owns the lock lifecycle and is the only writer; root-level
/// overlays that render OUTSIDE the gated home subtree (notably [CallOverlay],
/// mounted via MaterialApp.builder) listen so they never paint call UI —
/// caller identity, video — over the lock screen. A call in progress keeps
/// its audio; only its UI waits for the unlock.
final ValueNotifier<bool> appLockedListenable = ValueNotifier<bool>(false);

/// Triggers the home shell's biometric unlock prompt. Set by the home shell;
/// used by the root-level lock screen in MaterialApp.builder, which lives
/// outside the shell's subtree and can't reach its state directly.
VoidCallback? appUnlockRequester;

/// Handles a PIN typed on the root-level lock screen. Set by the home shell
/// (which owns PIN classification: real unlock, duress-decoy, duress-wipe).
/// Returns true when the PIN unlocked (so the lock screen can clear/shake).
Future<bool> Function(String pin)? appPinUnlockHandler;

/// Whether an app-lock PIN is configured — the root-level lock screen shows
/// the PIN pad only when true. Maintained by the home shell and the security
/// settings screen (which lives inside the gated subtree and can't be asked
/// directly by the lock screen).
final ValueNotifier<bool> appPinConfiguredListenable = ValueNotifier<bool>(
  false,
);

/// Which face of the vault this session shows.
///
/// [VaultMode.real] is a normal session. [VaultMode.decoy] is entered by the
/// duress PIN: hidden conversations, wallet balances, and the vault's own
/// settings are invisible, and everything else behaves normally so the
/// session is indistinguishable from a real one to an observer. The mode is
/// decided at unlock time and only ever moves decoy→real through a real
/// unlock.
///
/// HONEST LIMIT: decoy mode is a UI filter, not an enclave — the hidden data
/// remains on the device, recoverable by forensic extraction. Its threat
/// model is the coerced unlock and the shoulder surfer; the duress-wipe
/// action (and the dead-man switch) are the answers to device seizure.
enum VaultMode { real, decoy }

final ValueNotifier<VaultMode> vaultModeListenable =
    ValueNotifier<VaultMode>(VaultMode.real);

/// Handles a remote device-wipe command received over WS/push/refresh.
/// Set by the home shell; the WS layer (ChatProvider) routes `device_wipe`
/// events here. The handler verifies the PGP signature against the account's
/// own key and the target session id before destroying anything.
Future<void> Function(Map<String, dynamic> payload)? deviceWipeRequestHandler;
