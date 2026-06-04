import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/call_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/key_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/bots/bot_chats_screen.dart';
import 'screens/call/call_screen.dart';
import 'screens/channels/channel_screen.dart';
import 'screens/home/conversations_screen.dart';
import 'screens/settings/pgp_keys_screen.dart';
import 'services/api_service.dart';
import 'services/app_access_gate.dart';
import 'services/background_ws_service.dart';
import 'services/call_service.dart';
import 'services/foreground_ws_notification_router.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/secure_storage_service.dart';
import 'services/websocket_service.dart';
import 'theme/app_theme.dart';
import 'widgets/glass.dart';

class OpenChatApp extends StatelessWidget {
  const OpenChatApp({super.key});

  /// Root navigator key, used to clear pushed routes on sign-out so the user
  /// lands on the login screen immediately rather than on whatever screen was
  /// on top of the stack when their session ended.
  static final navigatorKey = GlobalKey<NavigatorState>();

  /// Lets non-widget code (e.g. CallProvider) surface app-wide SnackBars such
  /// as the in-app missed-call banner.
  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context) {
    final seed = context.watch<SettingsProvider>().seedColor;
    return MaterialApp(
      title: 'OpenChat',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(seed: seed),
      darkTheme: AppTheme.dark(seed: seed),
      themeMode: ThemeMode.system,
      home: const _AppRoot(),
      // Float the call UI above every route so incoming/active calls surface on
      // any screen, not just the chats list. The live connection banner stays
      // above it so a broken websocket is always visible.
      //
      // When a call is minimized, inflate MediaQuery.padding.top by the bar
      // height so every screen's SafeArea and AppBar automatically push content
      // down — no per-screen wiring needed.
      builder: (context, child) {
        final extra = context
            .select<CallProvider, double>((cp) => cp.minimizedContentTopInset);
        final mq = MediaQuery.of(context);
        return Stack(
          children: [
            MediaQuery(
              data: extra == 0
                  ? mq
                  : mq.copyWith(
                      padding: mq.padding.copyWith(
                        top: mq.padding.top + extra,
                      ),
                    ),
              child: child!,
            ),
            const CallOverlay(),
            const _LiveConnectionBanner(),
          ],
        );
      },
    );
  }
}

class _LiveConnectionBanner extends StatelessWidget {
  const _LiveConnectionBanner();

  @override
  Widget build(BuildContext context) {
    final authenticated = context.select<AuthProvider, bool>(
      (auth) => auth.state == AuthState.authenticated,
    );
    final monitoring = context.select<WebSocketService, bool>(
      (ws) => ws.isMonitoring,
    );
    final show = authenticated && !monitoring;
    final scheme = Theme.of(context).colorScheme;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: SafeArea(
          bottom: false,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -1),
                end: Offset.zero,
              ).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: show
                ? Padding(
                    key: const Key('websocket-connecting-banner'),
                    padding: const EdgeInsets.only(top: 8),
                    child: Center(
                      child: LiquidGlass.capsule(
                        tint: scheme.primary,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                  color: scheme.primary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Connecting…',
                                style: TextStyle(
                                  color: scheme.primary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(key: Key('websocket-connected')),
          ),
        ),
      ),
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();
  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  AuthState _lastAuthState = AuthState.unknown;
  bool _appLocked = false;
  bool _appLockEnabled = false;
  bool _promptingAppUnlock = false;
  AppLifecycleListener? _lifecycleListener;
  StreamSubscription<WsEvent>? _wsForegroundSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final auth = context.read<AuthProvider>();
      context.read<ApiService>().onAuthFailed = auth.logout;
      auth.addListener(_onAuthChanged);
      auth.initialize();
      context.read<KeyProvider>().load();
      context.read<CallProvider>().addListener(_onCallChanged);
      PushNotificationService.setForegroundIncomingCallHandler((data) {
        context.read<CallProvider>().handleIncomingCallPush(data);
      });
      _wsForegroundSub = context.read<WebSocketService>().events.listen(
        _onForegroundWsEvent,
      );

      // Cache the app-lock preference.
      final storage = context.read<SecureStorageService>();
      _appLockEnabled = await storage.getAppLockEnabled();
      final shouldLockOnLaunch = _appLockEnabled && await storage.isLoggedIn();
      if (mounted && shouldLockOnLaunch) {
        setState(() => _appLocked = true);
      }
      _lifecycleListener = AppLifecycleListener(
        onHide: _onBackground,
        onPause: _onBackground,
        onResume: _onForeground,
      );
      NotificationService.setAppFocused(true);
    });
  }

  void _onBackground() {
    NotificationService.setAppFocused(false);
    context.read<CallProvider>().refreshActiveCallNotification();
    final storage = context.read<SecureStorageService>();
    storage.getAppLockEnabled().then((enabled) {
      if (!mounted) return;
      _appLockEnabled = enabled;
      if (_appLockEnabled) {
        setState(() => _appLocked = true);
      } else if (_appLocked) {
        setState(() => _appLocked = false);
      }
    });
    if (_appLockEnabled) {
      setState(() => _appLocked = true);
    }
  }

  void _onForeground() {
    NotificationService.setAppFocused(true);
    context.read<CallProvider>().refreshActiveCallNotification();
    if (context.read<AuthProvider>().state == AuthState.authenticated) {
      unawaited(context.read<ChatProvider>().connectWebSocket());
      unawaited(context.read<ChatProvider>().refreshConversationsSilently());
    }
    final storage = context.read<SecureStorageService>();
    storage.getAppLockEnabled().then((enabled) {
      if (!mounted) return;
      _appLockEnabled = enabled;
      if (!_appLockEnabled && _appLocked) {
        setState(() => _appLocked = false);
      } else if (_appLocked) {
        _promptAppUnlock();
      }
    });
  }

  Future<void> _promptAppUnlock() async {
    if (_promptingAppUnlock) return;
    _promptingAppUnlock = true;
    final auth = LocalAuthentication();
    try {
      final ok = await auth.authenticate(localizedReason: 'Unlock OpenChat');
      if (ok && mounted) setState(() => _appLocked = false);
    } catch (_) {
      // If biometrics fail (e.g. no enrolled biometrics), stay locked but
      // allow the user to try again via the lock-screen button.
    } finally {
      _promptingAppUnlock = false;
    }
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    _wsForegroundSub?.cancel();
    PushNotificationService.setForegroundIncomingCallHandler(null);
    context.read<AuthProvider>().removeListener(_onAuthChanged);
    context.read<CallProvider>().removeListener(_onCallChanged);
    super.dispose();
  }

  void _onForegroundWsEvent(WsEvent event) {
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);

    final showSensitive = context
        .read<SettingsProvider>()
        .notificationSensitiveContent;
    final intent = ForegroundWsNotificationRouter.intentForEvent(
      event,
      showSensitive: showSensitive,
      isDesktop: isDesktop,
    );
    if (intent == null) return;

    switch (intent.kind) {
      case NotificationIntentKind.message:
        NotificationService.showMessage(
          conversationId: (event.data['conversation_id'] as String?) ?? 'ws',
          title: intent.title,
          body: intent.body,
          showSensitive: true,
        );
        break;
      case NotificationIntentKind.incomingCall:
        NotificationService.showIncomingCall(body: intent.body);
        break;
    }
  }

  void _onCallChanged() {
    final call = context.read<CallProvider>();

    final missed = call.lastMissedCall;
    if (missed != null) {
      // Consume it so the banner shows exactly once.
      call.clearMissedCall();
      final kind = missed.isVideo ? 'video' : 'voice';
      OpenChatApp.scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Missed $kind call')),
      );
    }

    // An outgoing call ended — record it in the DM thread as a deletable event.
    final ended = call.lastEndedCall;
    if (ended != null) {
      call.clearEndedCall();
      context.read<ChatProvider>().postCallEvent(
        convID: ended.conversationId,
        answered: ended.answered,
        isVideo: ended.isVideo,
        durationSecs: ended.durationSecs,
      );
    }
  }

  void _onAuthChanged() {
    final auth = context.read<AuthProvider>();
    if (auth.state == AuthState.authenticated &&
        _lastAuthState != AuthState.authenticated) {
      _fetchIceServers();
      context.read<KeyProvider>().load();
      context.read<ChatProvider>().connectWebSocket();
      // Re-register the FCM/APNs push token on every login so the backend
      // always has a current token. Silently skipped when Firebase credentials
      // are placeholders or push notifications have not been enabled.
      unawaited(_initPushFromSettingsIfEnabled());
    } else if (auth.state == AuthState.unauthenticated &&
        _lastAuthState == AuthState.authenticated) {
      context.read<ChatProvider>().clearState();
      // Drop any pushed routes (Settings, an open chat, etc.) so the rebuilt
      // root shows the login screen instead of stranding the user on top of a
      // now-defunct authenticated screen.
      OpenChatApp.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    _lastAuthState = auth.state;
  }

  Future<void> _initPushFromSettingsIfEnabled() async {
    final settings = context.read<SettingsProvider>();
    final api = context.read<ApiService>();
    await settings.load();
    if (!mounted || !settings.pushNotificationsEnabled) return;
    await PushNotificationService.initFromSettings(api: api);
  }

  Future<void> _fetchIceServers() async {
    try {
      final servers = await context.read<ApiService>().getIceServers();
      if (mounted && servers.isNotEmpty) {
        context.read<CallService>().updateIceServers(servers);
      }
    } catch (_) {
      // Silently fall back to default STUN servers baked into CallService
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final gate = AppAccessGateDecision.resolve(
      authenticated: auth.state == AuthState.authenticated,
      appLockEnabled: _appLockEnabled,
      appLocked: _appLocked,
      biometricKeyExportEnabled: false,
    );

    if (gate == AppAccessGateDecision.showAppLock) {
      return _AppLockScreen(onUnlock: _promptAppUnlock);
    }

    return switch (auth.state) {
      AuthState.unknown => Scaffold(
        body: LiquidMeshBackground(
          child: Center(
            child: LiquidGlass(
              blur: 32,
              borderRadius: const BorderRadius.all(Radius.circular(32)),
              padding: const EdgeInsets.all(36),
              child: const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ),
        ),
      ),
      AuthState.unauthenticated => const LoginScreen(),
      AuthState.authenticated => const _HomeShell(),
    };
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell();
  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    final settings = context.watch<SettingsProvider>();

    // Chats is always present. Channels and Bots get their own tab only when the
    // user opts in; otherwise those conversations surface inside Chats.
    final screens = <Widget>[const ConversationsScreen()];
    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline),
        selectedIcon: Icon(Icons.chat_bubble),
        label: 'Chats',
      ),
    ];
    if (settings.channelsOwnTab) {
      screens.add(const ChannelListScreen());
      destinations.add(
        const NavigationDestination(
          icon: Icon(Icons.campaign_outlined),
          selectedIcon: Icon(Icons.campaign),
          label: 'Channels',
        ),
      );
    }
    if (settings.botsOwnTab) {
      screens.add(const BotChatsScreen());
      destinations.add(
        const NavigationDestination(
          icon: Icon(Icons.smart_toy_outlined),
          selectedIcon: Icon(Icons.smart_toy),
          label: 'Bots',
        ),
      );
    }

    // Clamp in case a tab was just turned off while it was selected.
    if (_tab >= screens.length) _tab = 0;

    return Scaffold(
      // Let content flow behind the translucent glass bar.
      extendBody: true,
      body: Column(
        children: [
          if (user != null && user.isKeyExpired) _ExpiredKeyBanner(user: user),
          Expanded(
            child: IndexedStack(index: _tab, children: screens),
          ),
        ],
      ),
      // A single-entry nav bar carries no information, so hide it entirely.
      // Otherwise it floats as a detached Liquid Glass capsule (16dp side
      // margins) so the conversation canvas refracts beneath it as it scrolls.
      bottomNavigationBar: destinations.length < 2
          ? null
          : Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                MediaQuery.viewPaddingOf(context).bottom + 6,
              ),
              child: LiquidGlass.capsule(
                // The capsule already clears the home-bar inset, so stop the
                // NavigationBar from adding its own and double-padding.
                child: MediaQuery.removePadding(
                  context: context,
                  removeBottom: true,
                  child: NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    destinations: destinations,
                  ),
                ),
              ),
            ),
    );
  }
}

class _AppLockScreen extends StatelessWidget {
  final VoidCallback onUnlock;
  const _AppLockScreen({required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: LiquidMeshBackground(
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: LiquidGlass(
                blur: 36,
                borderRadius: const BorderRadius.all(Radius.circular(40)),
                padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Lock icon with glow
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [scheme.primary, scheme.tertiary],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.45),
                            blurRadius: 28,
                            spreadRadius: -4,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.lock_outline_rounded,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'OpenChat is Locked',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Authenticate to continue',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.55),
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      height: 52,
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: onUnlock,
                        icon: const Icon(Icons.fingerprint_rounded),
                        label: const Text('Unlock'),
                        style: FilledButton.styleFrom(
                          shape: const StadiumBorder(),
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Persistent banner pinned to the top of the home shell whenever the
/// signed-in user's PGP key has elapsed its expiry. Sending and receiving
/// are server-blocked (HTTP 423) until they rotate, so we route them
/// straight to PgpKeysScreen.
class _ExpiredKeyBanner extends StatelessWidget {
  final dynamic user;
  const _ExpiredKeyBanner({required this.user});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PgpKeysScreen()),
      ),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: scheme.error.withValues(alpha: 0.32),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.error.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.error.withValues(alpha: 0.20),
              ),
              child: Icon(
                Icons.lock_clock_outlined,
                color: scheme.error,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PGP key expired',
                    style: TextStyle(
                      color: scheme.error,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    'You can\'t send or receive messages. Tap to rotate.',
                    style: TextStyle(
                      color: scheme.error.withValues(alpha: 0.75),
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.arrow_forward_ios_rounded,
              color: scheme.error.withValues(alpha: 0.70),
              size: 14,
            ),
          ],
        ),
      ),
    );
  }
}
