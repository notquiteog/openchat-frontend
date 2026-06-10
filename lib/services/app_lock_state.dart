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
