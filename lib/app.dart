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
      // any screen, not just the chats list.
      builder: (context, child) =>
          Stack(children: [if (child != null) child, const CallOverlay()]),
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
      final settings = context.read<SettingsProvider>();
      if (settings.pushNotificationsEnabled) {
        PushNotificationService.initFromSettings(
          api: context.read<ApiService>(),
        );
      }
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
      AuthState.unknown => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
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
    final scheme = Theme.of(context).colorScheme;

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
      bottomNavigationBar: destinations.length < 2
          ? null
          : GlassSurface(
              blur: 22,
              border: Border(
                top: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.35),
                ),
              ),
              child: NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: destinations,
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
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'OpenChat is locked',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Authenticate to continue',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.fingerprint),
              label: const Text('Unlock'),
            ),
          ],
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
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PgpKeysScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.lock_clock, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your PGP key has expired',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'You can’t send or receive messages until you rotate to a new key. Tap to fix.',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onErrorContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
