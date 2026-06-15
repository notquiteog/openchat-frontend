import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:share_handler/share_handler.dart';
import 'models/conversation.dart';
import 'providers/auth_provider.dart';
import 'providers/call_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/key_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/bots/bot_chats_screen.dart';
import 'screens/call/call_screen.dart';
import 'screens/call/sfu_call_screen.dart';
import 'services/call_service.dart' show EscalatedCall;
import 'services/sfu_call_controller.dart';
import 'screens/channels/channel_screen.dart';
import 'screens/chat/chat_screen.dart';
import 'screens/home/conversations_screen.dart';
import 'screens/invites/invite_preview_screen.dart';
import 'screens/onboarding/privacy_onboarding_screen.dart';
import 'screens/settings/pgp_keys_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'services/api_service.dart';
import 'services/app_access_gate.dart';
import 'crypto/pgp_service.dart';
import 'services/app_lock_state.dart';
import 'services/local_wipe_service.dart';
import 'services/background_ws_service.dart';
import 'services/badge_service.dart';
import 'services/desktop_startup_service.dart';
import 'services/mls_service.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/secure_storage_service.dart';
import 'services/websocket_service.dart';
import 'theme/app_theme.dart';
import 'utils/invite_links.dart';
import 'utils/identity_qr.dart';
import 'widgets/chat_search_results_view.dart';
import 'widgets/desktop.dart';
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
    final settings = context.watch<SettingsProvider>();
    final seed = settings.seedColor;
    final reduceTransparency = settings.reduceTransparency;
    return MaterialApp(
      title: 'OpenChat',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      scrollBehavior: OpenChatScrollBehavior(
        reduceTransparency: reduceTransparency,
      ),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(seed: seed, reduceTransparency: reduceTransparency),
      darkTheme: AppTheme.dark(
        seed: seed,
        reduceTransparency: reduceTransparency,
      ),
      themeMode: settings.themeMode,
      home: const _AppRoot(),
      // Float call + live-location bars above every route so they persist while
      // navigating. The live connection banner stays topmost.
      //
      // MediaQuery.padding.top inflation means every screen's SafeArea/AppBar
      // automatically reserves space — no per-screen wiring needed.
      //
      // Stack layer order (bottom → top / back → front):
      //   1. child wrapped in fully-inflated MediaQuery (call + location inset)
      //   2. CallOverlay wrapped in location-only-inflated MediaQuery so its
      //      internal SafeArea places the call bar below the location bar.
      //   3. _LocationBarOverlay — original MediaQuery → sits at very top.
      //   4. _LiveConnectionBanner — connection error, always topmost.
      builder: (context, child) {
        final reduceTransparency = context.select<SettingsProvider, bool>(
          (s) => s.reduceTransparency,
        );
        final callExtra = context.select<CallProvider, double>(
          (cp) => cp.minimizedContentTopInset,
        );
        // Suppress the location bar inset during a full-screen video call.
        // The bar itself is hidden in that state (see _LocationBarOverlay) to
        // prevent its GlassContainer's BackdropFilter from rendering above the
        // RTCVideoView platform texture, which causes white tiles on desktop.
        final isFullScreenVideoCall = context.select<CallProvider, bool>(
          (cp) =>
              cp.isInCall && cp.session?.isVideo == true && !cp.isCallMinimized,
        );
        final rawLocExtra = context.select<ChatProvider, double>(
          (chat) => chat.liveLocationTopInset,
        );
        final locExtra = isFullScreenVideoCall ? 0.0 : rawLocExtra;
        final mq = MediaQuery.of(context);

        MediaQueryData withTop(double extra) => extra == 0
            ? mq
            : mq.copyWith(
                padding: mq.padding.copyWith(top: mq.padding.top + extra),
              );

        // Routes without a Material ancestor (Cupertino modal popups — e.g.
        // showGlassActionSheet — render in the navigator Overlay, above any
        // Scaffold) would otherwise inherit MaterialApp's debug fallback text
        // style: monospace, red, yellow double underline. Give the whole
        // navigator a sane DefaultTextStyle instead. Like the overlay wrappers
        // below, DefaultTextStyle adds no render objects, so the liquid-glass
        // BackdropFilter chain is unaffected (see the Material(transparency)
        // warning further down).
        final baseTextStyle =
            Theme.of(context).textTheme.bodyMedium ?? const TextStyle();

        Widget appChrome = Stack(
          children: [
            // Screens — pushed down past both bars.
            MediaQuery(
              data: withTop(callExtra + locExtra),
              child: DefaultTextStyle(style: baseTextStyle, child: child!),
            ),
            // Call bar — sees location offset so SafeArea places it below the
            // location bar when both are active.
            //
            // Why DefaultTextStyle.merge instead of Material(transparency):
            //
            // MaterialApp.builder runs inside AnimatedTheme but OUTSIDE any
            // Material widget, so DefaultTextStyle.of() returns Flutter's debug
            // fallback (monospace font, yellow underline) — wrapping in something
            // that sets a real DefaultTextStyle is required for correct text style.
            //
            // We CANNOT use Material(type: MaterialType.transparency) because it
            // adds _InkFeatures / PhysicalShape render objects. Those render objects
            // alter the compositing chain around LightweightLiquidGlass's
            // BackdropFilterLayer, causing it to read from an isolated or empty
            // layer and paint the glass surface solid white over the entire app.
            // Additionally, _LiveConnectionBanner.build() returns a Positioned
            // widget that MUST be a direct RenderStack child; inserting any widget
            // with its own RenderObject (Material has several) between the Stack
            // and the Positioned breaks applyParentData and the banner inherits
            // full-screen constraints, compounding the white-layer corruption.
            //
            // DefaultTextStyle.merge is safe: it composes Builder + InheritedWidget,
            // neither of which introduce RenderObjects. In the render tree every
            // overlay widget remains a direct child of RenderStack, so Positioned
            // and BackdropFilterLayer both work exactly as if the wrapper
            // weren't there.
            MediaQuery(
              data: withTop(locExtra),
              child: DefaultTextStyle.merge(
                style: const TextStyle(decoration: TextDecoration.none),
                child: const CallOverlay(),
              ),
            ),
            // Location bar — sees no extra offset → anchors at the very top.
            DefaultTextStyle.merge(
              style: const TextStyle(decoration: TextDecoration.none),
              child: const _LocationBarOverlay(),
            ),
            // Connection banner — build() returns Positioned, which needs to be
            // an effective direct RenderStack child. DefaultTextStyle.merge
            // satisfies that requirement (no render objects in the path).
            DefaultTextStyle.merge(
              style: const TextStyle(decoration: TextDecoration.none),
              child: const _LiveConnectionBanner(),
            ),
          ],
        );

        // App lock. The home-route gate in _AppRoot cannot cover PUSHED
        // routes (they sit above home in the navigator) nor the root
        // overlays in this Stack (call UI, location bar) — so while locked
        // the entire chrome is visually replaced here. Offstage keeps the
        // navigator and any in-progress call alive (audio continues, no
        // state is lost) but paints nothing and accepts no input.
        appChrome = ValueListenableBuilder<bool>(
          valueListenable: appLockedListenable,
          builder: (context, locked, chrome) {
            if (!locked) return chrome!;
            return Stack(
              children: [
                Offstage(child: chrome),
                _AppLockScreen(onUnlock: () => appUnlockRequester?.call()),
              ],
            );
          },
          child: appChrome,
        );

        if (reduceTransparency) {
          appChrome = GlassTheme(
            data: _reducedTransparencyGlassTheme(context),
            child: appChrome,
          );
        }

        return GlassAccessibilityScope(
          reduceTransparency: reduceTransparency,
          child: appChrome,
        );
      },
    );
  }
}

GlassThemeData _reducedTransparencyGlassTheme(BuildContext context) {
  final fill = reducedGlassSurfaceColor(context);
  final settings = GlassThemeSettings(
    glassColor: fill,
    thickness: 0,
    blur: 0,
    chromaticAberration: 0,
    lightIntensity: 0,
    ambientStrength: 0,
    saturation: 1,
  );
  final variant = GlassThemeVariant(
    settings: settings,
    quality: GlassQuality.minimal,
  );
  return GlassThemeData(light: variant, dark: variant);
}

// ── Global live-location bar ──────────────────────────────────────────────────

/// App-wide overlay that mirrors the minimized call bar: sits in the SafeArea
/// top zone, reserves space via MediaQuery inflation, and persists across
/// navigation. Positioned above the call bar when both are active.
class _LocationBarOverlay extends StatefulWidget {
  const _LocationBarOverlay();

  @override
  State<_LocationBarOverlay> createState() => _LocationBarOverlayState();
}

class _LocationBarOverlayState extends State<_LocationBarOverlay> {
  // Tick every second so the remaining-time label stays fresh.
  late final _ticker = Stream<void>.periodic(const Duration(seconds: 1));
  late final _sub = _ticker.listen((_) {
    if (mounted) setState(() {});
  });

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  void _openConversation(BuildContext context, String conversationId) {
    try {
      final chat = context.read<ChatProvider>();
      final conv = chat.conversations.firstWhere((c) => c.id == conversationId);
      Navigator.of(
        context,
        rootNavigator: true,
      ).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)));
    } catch (_) {
      // Conversation may not be loaded yet; ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final share = chat.anyActiveLiveLocationShare;
    if (share == null) return const SizedBox.shrink();

    // During a full-screen video call the RTCVideoView fills the window as a
    // platform texture. Rendering GlassContainer (BackdropFilter) above it
    // confuses desktop compositors and produces white tiles + broken hit tests.
    // Hide the bar until the call ends or is minimised; the inset is also
    // suppressed in the builder above so the call chrome layout is unaffected.
    final cp = context.watch<CallProvider>();
    if (cp.isInCall && cp.session?.isVideo == true && !cp.isCallMinimized) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final remaining = share.expiresAt.difference(DateTime.now());
    final label = remaining.inSeconds <= 0
        ? 'ending'
        : remaining.inHours >= 1
        ? (remaining.inMinutes % 60 == 0
              ? '${remaining.inHours}h left'
              : '${remaining.inHours}h ${remaining.inMinutes % 60}m left')
        : remaining.inMinutes >= 1
        ? '${remaining.inMinutes}m left'
        : '${remaining.inSeconds}s left';

    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        bottom: false,
        left: false,
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: GestureDetector(
            onTap: () => _openConversation(context, share.conversationId),
            child: GlassContainer(
              shape: LiquidRoundedSuperellipse(borderRadius: 999),
              allowElevation: true,
              glowIntensity: 0.10,
              padding: EdgeInsets.zero,
              child: SizedBox(
                height: ChatProvider.liveLocationBarHeight,
                width: double.infinity,
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    // Green live-location dot — mirrors call bar's green pulse dot.
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFF34C759),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Sharing with ${share.sharingWith}',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            'Live location · $label',
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.55),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Open conversation button — mirrors expand button in call bar.
                    GestureDetector(
                      onTap: () =>
                          _openConversation(context, share.conversationId),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22),
                            width: 0.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.open_in_full_rounded,
                          color: Colors.white70,
                          size: 15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Stop sharing button — mirrors end-call button in call bar.
                    GestureDetector(
                      onTap: () => context
                          .read<ChatProvider>()
                          .stopLiveLocation(share.messageId),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(
                            0xFFFF3B30,
                          ).withValues(alpha: 0.88),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFFFF3B30,
                              ).withValues(alpha: 0.38),
                              blurRadius: 10,
                              spreadRadius: -3,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.location_off_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
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
                      child: GlassContainer(
                        shape: LiquidRoundedSuperellipse(borderRadius: 999),
                        allowElevation: true,
                        glowIntensity: 0.14,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GlassProgressIndicator.circular(
                                size: 14,
                                strokeWidth: 2.0,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Connecting…',
                                style: TextStyle(
                                  color: scheme.primary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.1,
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
  StreamSubscription<Uri>? _inviteLinkSub;
  Timer? _reminderTimer;
  SettingsProvider? _settings;
  String? _pendingInviteToken;
  String? _lastInviteToken;
  DateTime? _lastInviteHandledAt;
  bool _handlingInviteLink = false;
  String? _pendingContactToken;
  String? _lastContactToken;
  DateTime? _lastContactHandledAt;
  bool _handlingContactLink = false;
  String? _pendingPushConversationId;
  bool _handlingPushConversation = false;
  StreamSubscription<SharedMedia>? _shareSub;
  String? _pendingShareText;
  bool _handlingShare = false;
  StreamSubscription<EscalatedCall>? _escalatedCallSub;
  final BadgeService _badgeService = BadgeService();

  @override
  void initState() {
    super.initState();
    appUnlockRequester = _promptAppUnlock;
    _initInviteLinks();
    _initShareIntake();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final auth = context.read<AuthProvider>();
      final settings = context.read<SettingsProvider>();
      _settings = settings;
      settings.addListener(_onSettingsChanged);
      // Launcher/tray unread badge — client-computed (push payloads stay
      // opaque, so the server never knows unread counts).
      _badgeService.attach(context.read<ChatProvider>(), settings);
      final tray = DesktopStartupService.tray;
      if (tray != null) {
        _badgeService.trayBadgeApplier = tray.setUnreadBadge;
      }
      unawaited(
        settings.load().then((_) {
          if (mounted) _syncNotificationPreferences(settings);
        }),
      );
      context.read<ApiService>().onAuthFailed = auth.logout;
      auth.addListener(_onAuthChanged);
      auth.initialize();
      context.read<KeyProvider>().load();
      context.read<CallProvider>().addListener(_onCallChanged);
      // Mesh→SFU escalation: the mesh side is already torn down when this
      // fires; join the LiveKit room and surface the SFU call UI.
      _escalatedCallSub = context.read<CallProvider>().escalatedCalls.listen(
        _onCallEscalated,
      );
      PushNotificationService.setForegroundIncomingCallHandler((data) async {
        await context.read<CallProvider>().handleIncomingCallPush(data);
      });
      NotificationService.setIncomingCallPayloadHandler(
        onPayload: (data) async {
          await context.read<CallProvider>().handleIncomingCallPush(data);
        },
      );
      PushNotificationService.setNotificationOpenedHandler(
        _queuePushConversation,
      );
      // Local message/reminder notification taps route through the same
      // pending-conversation queue as FCM taps (cold-start taps are queued by
      // NotificationService until this handler lands).
      NotificationService.setMessageOpenedHandler((conversationId) {
        // On desktop the app may be hidden in the tray — restore it first.
        final tray = DesktopStartupService.tray;
        if (tray != null) unawaited(tray.showWindow());
        _queuePushConversation(conversationId);
      });
      // NOTE: no separate desktop WS→notification subscription here.
      // ChatProvider (rich decrypted message previews) and CallProvider
      // (incoming-call alerts) already post notifications for these events —
      // a second subscriber double-fired and raced the generic "New message"
      // banner against the decrypted one.

      // Cache the app-lock preference.
      final storage = context.read<SecureStorageService>();
      _appLockEnabled = await storage.getAppLockEnabled();
      appPinConfiguredListenable.value = await storage.hasAppLockPin();
      appPinUnlockHandler = _handleAppLockPin;
      deviceWipeRequestHandler = _handleDeviceWipeCommand;
      // Dead-man switch runs BEFORE any unlock: a device opened after the
      // configured silence window wipes instead of presenting the lock.
      await _checkDeadmanSwitch();
      final shouldLockOnLaunch = _appLockEnabled && await storage.isLoggedIn();
      if (mounted && shouldLockOnLaunch) {
        _setAppLocked(true);
      } else if (await storage.isLoggedIn()) {
        // No lock gate: opening the app is itself proof of presence.
        unawaited(storage.recordRealUnlock());
      }
      _lifecycleListener = AppLifecycleListener(
        onHide: _onBackground,
        onPause: _onBackground,
        onResume: _onForeground,
      );
      NotificationService.setAppFocused(true);
      _reminderTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _surfaceDueReminders(),
      );
      _surfaceDueReminders();
    });
  }

  void _initInviteLinks() {
    try {
      _inviteLinkSub = AppLinks().uriLinkStream.listen(
        _queueDeepLink,
        onError: (_) {},
      );
    } catch (_) {
      // Deep links are best-effort on unsupported test/desktop runners.
    }
  }

  // ── Inbound share (OS "Share to OpenChat") ──────────────────────────────────
  // Android only for now, text/URL only. iOS additionally needs a Share
  // Extension + App Group; shared files need the attachment pipeline — both
  // tracked as follow-ups.
  void _initShareIntake() {
    try {
      final handler = ShareHandler.instance;
      _shareSub = handler.sharedMediaStream.listen(
        _handleSharedMedia,
        onError: (_) {},
      );
      handler.getInitialSharedMedia().then((media) {
        if (media == null) return;
        _handleSharedMedia(media);
        handler.resetInitialSharedMedia();
      });
    } catch (_) {
      // Share intents are mobile-only; no-op on desktop/test runners.
    }
  }

  void _handleSharedMedia(SharedMedia media) {
    // v1: text/URL only. Attachments (media.attachments) need the upload
    // pipeline, and iOS needs a Share Extension + App Group — both follow-ups.
    final text = media.content?.trim() ?? '';
    if (text.isEmpty) return;
    _pendingShareText = text;
    _drainPendingShare();
  }

  void _drainPendingShare() {
    if (!mounted || _handlingShare) return;
    final text = _pendingShareText;
    if (text == null) return;
    if (_appLocked) return;
    if (context.read<AuthProvider>().state != AuthState.authenticated) return;
    final navigator = OpenChatApp.navigatorKey.currentState;
    if (navigator == null) return;

    _pendingShareText = null;
    _handlingShare = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _handlingShare = false;
        return;
      }
      try {
        final target = await _pickShareTarget(navigator.context);
        if (target != null && mounted) {
          final messenger = ScaffoldMessenger.maybeOf(navigator.context);
          final sent = await context.read<ChatProvider>().sendMessage(
            convID: target.id,
            plaintext: text,
          );
          messenger?.showSnackBar(
            SnackBar(content: Text(sent ? 'Shared' : 'Could not share')),
          );
        }
      } finally {
        if (mounted) _handlingShare = false;
      }
    });
  }

  Future<Conversation?> _pickShareTarget(BuildContext sheetContext) {
    final chat = context.read<ChatProvider>();
    final selfId = context.read<AuthProvider>().currentUser?.id ?? '';
    final targets = chat.conversations.toList(growable: false);
    if (targets.isEmpty) return Future<Conversation?>.value(null);
    return showModalBottomSheet<Conversation>(
      context: sheetContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return GlassBottomSheetFrame(
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlassSheetGrabber(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Share to',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: targets.length,
                    itemBuilder: (_, i) {
                      final c = targets[i];
                      final label = c.displayName(selfId);
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: scheme.primaryContainer,
                          child: Text(
                            label.isNotEmpty ? label[0].toUpperCase() : '#',
                            style: TextStyle(color: scheme.onPrimaryContainer),
                          ),
                        ),
                        title: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(ctx, c),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _queueDeepLink(Uri uri) {
    final inviteToken = inviteTokenFromUri(uri);
    if (inviteToken != null) {
      _pendingInviteToken = inviteToken;
      _drainPendingInviteLink();
      return;
    }
    final contactToken = contactLinkTokenFromUri(uri);
    if (contactToken == null) return;
    _pendingContactToken = contactToken;
    _drainPendingContactLink();
  }

  void _drainPendingInviteLink() {
    if (!mounted || _handlingInviteLink) return;
    final token = _pendingInviteToken;
    if (token == null) return;
    if (_appLocked) return;
    if (context.read<AuthProvider>().state != AuthState.authenticated) return;

    final navigator = OpenChatApp.navigatorKey.currentState;
    if (navigator == null) return;

    final now = DateTime.now();
    final handledRecently =
        _lastInviteToken == token &&
        _lastInviteHandledAt != null &&
        now.difference(_lastInviteHandledAt!) < const Duration(seconds: 2);
    if (handledRecently) {
      _pendingInviteToken = null;
      return;
    }

    _pendingInviteToken = null;
    _handlingInviteLink = true;
    _lastInviteToken = token;
    _lastInviteHandledAt = now;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _handlingInviteLink = false;
        return;
      }
      try {
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => InvitePreviewScreen(token: token),
          ),
        );
      } finally {
        if (mounted) _handlingInviteLink = false;
      }
      if (!mounted) return;
      _drainPendingInviteLink();
    });
  }

  void _drainPendingContactLink() {
    if (!mounted || _handlingContactLink) return;
    final token = _pendingContactToken;
    if (token == null) return;
    if (_appLocked) return;
    if (context.read<AuthProvider>().state != AuthState.authenticated) return;

    final now = DateTime.now();
    final handledRecently =
        _lastContactToken == token &&
        _lastContactHandledAt != null &&
        now.difference(_lastContactHandledAt!) < const Duration(seconds: 2);
    if (handledRecently) {
      _pendingContactToken = null;
      return;
    }

    _pendingContactToken = null;
    _handlingContactLink = true;
    _lastContactToken = token;
    _lastContactHandledAt = now;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _handlingContactLink = false;
        return;
      }
      final api = context.read<ApiService>();
      final settings = context.read<SettingsProvider>();
      try {
        final contact = await api.claimContactLink(token);
        await settings.upsertPrivateContact(contact);
        OpenChatApp.scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Contact saved: ${contact.title}')),
        );
      } catch (e) {
        OpenChatApp.scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Contact link failed: $e')),
        );
      } finally {
        if (mounted) _handlingContactLink = false;
      }
      if (!mounted) return;
      _drainPendingContactLink();
    });
  }

  void _queuePushConversation(String conversationId) {
    final trimmed = conversationId.trim();
    if (trimmed.isEmpty) return;
    _pendingPushConversationId = trimmed;
    _drainPendingPushConversation();
  }

  void _drainPendingPushConversation() {
    if (!mounted || _handlingPushConversation) return;
    final conversationId = _pendingPushConversationId;
    if (conversationId == null) return;
    if (_appLocked) return;
    if (context.read<AuthProvider>().state != AuthState.authenticated) return;

    final navigator = OpenChatApp.navigatorKey.currentState;
    if (navigator == null) return;

    _pendingPushConversationId = null;
    _handlingPushConversation = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _handlingPushConversation = false;
        return;
      }
      try {
        final chat = context.read<ChatProvider>();
        final conv =
            chat.conversationById(conversationId) ??
            await chat.ensureConversationLoaded(conversationId);
        if (conv == null || !mounted) return;
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ChatScreen(conversation: conv),
          ),
        );
      } finally {
        if (mounted) _handlingPushConversation = false;
      }
      if (!mounted) return;
      _drainPendingPushConversation();
    });
  }

  /// Single writer for the lock state: the local field gates the home shell's
  /// build; the shared listenable gates root-level overlays (CallOverlay)
  /// that live outside this subtree and would otherwise paint over the lock.
  void _setAppLocked(bool locked) {
    if (_appLocked != locked) {
      setState(() => _appLocked = locked);
    }
    appLockedListenable.value = locked;
  }

  void _onBackground() {
    NotificationService.setAppFocused(false);
    unawaited(BackgroundWsService.updateForegroundState(false));
    context.read<CallProvider>().refreshActiveCallNotification();
    unawaited(context.read<ChatProvider>().refreshLiveLocationNotifications());
    final storage = context.read<SecureStorageService>();
    storage.getAppLockEnabled().then((enabled) {
      if (!mounted) return;
      _appLockEnabled = enabled;
      _setAppLocked(_appLockEnabled);
    });
    if (_appLockEnabled) {
      _setAppLocked(true);
    }
  }

  void _onForeground() {
    NotificationService.setAppFocused(true);
    unawaited(BackgroundWsService.updateForegroundState(true));
    context.read<CallProvider>().refreshActiveCallNotification();
    _surfaceDueReminders();
    unawaited(_checkDeadmanSwitch());
    if (context.read<AuthProvider>().state == AuthState.authenticated) {
      unawaited(context.read<ChatProvider>().connectWebSocket());
      unawaited(context.read<ChatProvider>().refreshConversationsSilently());
    }
    final storage = context.read<SecureStorageService>();
    storage.getAppLockEnabled().then((enabled) {
      if (!mounted) return;
      _appLockEnabled = enabled;
      if (!_appLockEnabled && _appLocked) {
        _setAppLocked(false);
        _drainPendingInviteLink();
        _drainPendingContactLink();
        _drainPendingPushConversation();
        _drainPendingShare();
      } else if (_appLocked) {
        _promptAppUnlock();
      } else {
        _drainPendingInviteLink();
        _drainPendingContactLink();
        _drainPendingPushConversation();
        _drainPendingShare();
      }
    });
  }

  Future<void> _promptAppUnlock() async {
    if (_promptingAppUnlock) return;
    _promptingAppUnlock = true;
    final auth = LocalAuthentication();
    try {
      final ok = await auth.authenticate(localizedReason: 'Unlock OpenChat');
      if (ok && mounted) {
        _completeRealUnlock();
      }
    } catch (_) {
      // If biometrics fail (e.g. no enrolled biometrics), stay locked but
      // allow the user to try again via the lock-screen button or PIN.
    } finally {
      _promptingAppUnlock = false;
    }
  }

  /// Shared tail of every REAL unlock (biometric or real PIN): the session
  /// shows the real vault, the dead-man clock resets, queued intents drain.
  void _completeRealUnlock() {
    vaultModeListenable.value = VaultMode.real;
    unawaited(context.read<SecureStorageService>().recordRealUnlock());
    _setAppLocked(false);
    _drainPendingInviteLink();
    _drainPendingContactLink();
    _drainPendingPushConversation();
    _drainPendingShare();
  }

  /// PIN entry from the root lock screen. Returns false only for a WRONG pin —
  /// the duress code reports success and is indistinguishable from the real
  /// one to anyone watching the screen.
  Future<bool> _handleAppLockPin(String pin) async {
    final storage = context.read<SecureStorageService>();
    switch (await storage.classifyAppLockPin(pin)) {
      case AppLockPinKind.real:
        if (mounted) _completeRealUnlock();
        return true;
      case AppLockPinKind.duress:
        final action = await storage.getDuressAction();
        if (action == 'wipe') {
          // Silent: destroy local data, then land on the fresh-install
          // landing screen as if the unlock simply succeeded into a clean app.
          await _runLocalWipe();
          return true;
        }
        if (mounted) {
          vaultModeListenable.value = VaultMode.decoy;
          // Deliberately NOT recording a real unlock: a coerced decoy session
          // must not reset the dead-man clock.
          _setAppLocked(false);
        }
        return true;
      case AppLockPinKind.invalid:
        return false;
    }
  }

  /// Wipe local data when the app hasn't seen a real unlock for the
  /// configured number of days. Runs at launch and on every foreground,
  /// BEFORE the lock screen can be answered — a seized device opened past the
  /// window destroys its keys without offering an unlock at all.
  Future<void> _checkDeadmanSwitch() async {
    final storage = context.read<SecureStorageService>();
    final days = await storage.getDeadmanDays();
    if (days <= 0 || !await storage.isLoggedIn()) return;
    final last = await storage.getLastRealUnlockAt();
    if (last == null) {
      // Switch just armed: start the clock now instead of wiping instantly.
      await storage.recordRealUnlock();
      return;
    }
    if (DateTime.now().toUtc().difference(last) > Duration(days: days)) {
      await _runLocalWipe();
    }
  }

  /// Verifies and executes a remote device-wipe command. The signature must
  /// validate against OUR OWN stored account public key and the target must
  /// be THIS session — a malicious server cannot forge either.
  Future<void> _handleDeviceWipeCommand(Map<String, dynamic> payload) async {
    try {
      final storage = context.read<SecureStorageService>();
      final mySessionId = await storage.getSessionId();
      final commandRaw = payload['command']?.toString() ?? '';
      if (mySessionId == null || mySessionId.isEmpty || commandRaw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(commandRaw);
      if (decoded is! Map || decoded['openchat_device_wipe'] != 1) return;
      final target = decoded['session_id']?.toString() ?? '';
      final issuedAt = decoded['issued_at']?.toString() ?? '';
      final signature = decoded['signature']?.toString() ?? '';
      if (target.toLowerCase() != mySessionId.toLowerCase() ||
          signature.isEmpty) {
        return;
      }
      final publicKey = await storage.getPublicKey() ?? '';
      if (publicKey.isEmpty) return;
      final ok = await PgpService.verify(
        data: PgpService.deviceWipeSignedData(
          sessionId: target,
          issuedAt: issuedAt,
        ),
        signatureArmor: signature,
        signerPublicKeyArmored: publicKey,
      );
      if (!ok) return;
      await _runLocalWipe();
    } catch (_) {
      // Malformed command: ignore. Never wipe on anything unverified.
    }
  }

  Future<void> _runLocalWipe() async {
    final storage = context.read<SecureStorageService>();
    final auth = context.read<AuthProvider>();
    await LocalWipeService(storage).wipeEverything();
    vaultModeListenable.value = VaultMode.real;
    appPinConfiguredListenable.value = false;
    if (mounted) {
      _setAppLocked(false);
      await auth.logout();
    }
  }

  @override
  void dispose() {
    appUnlockRequester = null;
    _badgeService.dispose();
    _lifecycleListener?.dispose();
    _inviteLinkSub?.cancel();
    _escalatedCallSub?.cancel();
    _shareSub?.cancel();
    _reminderTimer?.cancel();
    PushNotificationService.setForegroundIncomingCallHandler(null);
    PushNotificationService.setNotificationOpenedHandler(null);
    NotificationService.setIncomingCallPayloadHandler();
    NotificationService.setMessageOpenedHandler(null);
    _settings?.removeListener(_onSettingsChanged);
    context.read<AuthProvider>().removeListener(_onAuthChanged);
    context.read<CallProvider>().removeListener(_onCallChanged);
    super.dispose();
  }

  void _onCallEscalated(EscalatedCall escalated) {
    if (!mounted) return;
    final sfu = context.read<SfuCallController>();
    final chat = context.read<ChatProvider>();
    final conv = chat.conversations
        .where((c) => c.id == escalated.conversationId)
        .firstOrNull;
    unawaited(
      sfu
          .join(
            conversationId: escalated.conversationId,
            title: conv?.name ?? 'Group call',
            isVideo: escalated.isVideo,
            e2eeKeyB64: escalated.e2eeKeyB64,
          )
          .catchError((Object e) {
            // Typically the server's premium gate on the LiveKit token.
            OpenChatApp.scaffoldMessengerKey.currentState?.showSnackBar(
              SnackBar(content: Text('Could not join the group call: $e')),
            );
          }),
    );
    OpenChatApp.navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const SfuCallScreen(),
      ),
    );
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
      final settings = _settings;
      if (settings != null && settings.isLoaded) {
        _syncNotificationPreferences(settings);
      }
      context.read<KeyProvider>().load();
      unawaited(_prepareMlsIdentity());
      context.read<ChatProvider>().connectWebSocket();
      _surfaceDueReminders();
      _drainPendingInviteLink();
      _drainPendingContactLink();
      _drainPendingPushConversation();
      // Re-register the FCM/APNs push token on every login so the backend
      // always has a current token. Silently skipped when Firebase credentials
      // are placeholders or push notifications have not been enabled.
      unawaited(_initPushFromSettingsIfEnabled());
      // Likewise restart the background WS channel if the user enabled it —
      // before this, the persisted setting only took effect again the next
      // time the settings toggle was flipped.
      unawaited(_startBackgroundWsIfEnabled());
      // macOS delivers nothing while authorization is notDetermined, and
      // unlike Android/iOS no other flow (FCM registration, the background-WS
      // toggle) asks early — without this, plain message notifications were
      // silently dropped until the user happened to start a call or set a
      // reminder.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
        unawaited(NotificationService.requestPermission());
      }
    } else if (auth.state == AuthState.unauthenticated &&
        _lastAuthState == AuthState.authenticated) {
      // Tear down the background notification channel: without this the
      // Android foreground service kept reconnecting with the logged-out
      // session's token (and resurrected itself after reboot). The persisted
      // setting stays on, so the next login restarts it.
      unawaited(BackgroundWsService.stop());
      context.read<ChatProvider>().clearState();
      // The persisted private blob was wiped in logout(); drop the in-memory
      // mirrors too so nothing can re-persist the old account's state and the
      // next account never sees its drafts/folders/contacts.
      context.read<SettingsProvider>().resetPrivateLocalState();
      // Drop any pushed routes (Settings, an open chat, etc.) so the rebuilt
      // root shows the login screen instead of stranding the user on top of a
      // now-defunct authenticated screen.
      OpenChatApp.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    _lastAuthState = auth.state;
  }

  void _onSettingsChanged() {
    final settings = _settings;
    if (settings == null || !settings.isLoaded) return;
    _syncNotificationPreferences(settings);
  }

  void _syncNotificationPreferences(SettingsProvider settings) {
    final preferences = settings.conversationNotificationPreferences;
    NotificationService.setConversationNotificationPreferences(preferences);
    unawaited(
      BackgroundWsService.updateConversationNotificationPreferences(
        preferences,
      ),
    );
    if (settings.wsBackgroundEnabled) {
      unawaited(
        BackgroundWsService.updateSensitiveContent(
          settings.notificationSensitiveContent,
        ),
      );
    }
    // Server-side mute sync: FCM message pushes carry an OS-displayed
    // Notification block, so muted chats must be skipped at the sender.
    if (settings.pushNotificationsEnabled) {
      unawaited(
        PushNotificationService.syncMutedRoutes(
          context.read<ApiService>(),
          settings.mutedConversationIds,
        ),
      );
    }
  }

  Future<void> _initPushFromSettingsIfEnabled() async {
    final settings = context.read<SettingsProvider>();
    final api = context.read<ApiService>();
    await settings.load();
    if (!mounted || !settings.pushNotificationsEnabled) return;
    await PushNotificationService.initFromSettings(api: api);
  }

  /// Restart the background WS service when the persisted setting is on.
  /// start() is idempotent: if the service is already running it just pushes
  /// the current token and notification rules into the isolate.
  Future<void> _startBackgroundWsIfEnabled() async {
    final settings = context.read<SettingsProvider>();
    final storage = context.read<SecureStorageService>();
    await settings.load();
    if (!mounted || !settings.wsBackgroundEnabled) return;
    final token = await storage.getAccessToken() ?? '';
    if (token.isEmpty) return;
    await BackgroundWsService.start(
      accessToken: token,
      showSensitive: settings.notificationSensitiveContent,
      conversationNotificationPreferences:
          settings.conversationNotificationPreferences,
    );
  }

  Future<void> _prepareMlsIdentity() async {
    if (!mounted) return;
    if (context.read<AuthProvider>().state != AuthState.authenticated) return;
    try {
      await context.read<MlsService>().ensureIdentityForCurrentUser();
    } catch (_) {
      // Best-effort local bootstrap. Sending to an MLS chat can still surface
      // a specific key/storage error if preparation was not possible.
    }
  }

  void _surfaceDueReminders() {
    if (!mounted || _appLocked) return;
    if (context.read<AuthProvider>().state != AuthState.authenticated) return;
    final settings = context.read<SettingsProvider>();
    if (!settings.isLoaded) return;
    final due = settings.dueMessageReminders(DateTime.now());
    for (final reminder in due) {
      unawaited(
        settings.removeMessageReminder(reminder.id, cancelNotification: false),
      );
      final title = reminder.conversationTitle.isEmpty
          ? 'Message reminder'
          : reminder.conversationTitle;
      final body = reminder.messagePreview.isEmpty
          ? 'OpenChat reminder'
          : reminder.messagePreview;
      unawaited(
        NotificationService.showMessageReminder(
          reminderId: reminder.id,
          title: title,
          body: body,
          conversationId: reminder.conversationId,
          messageId: reminder.messageId,
        ),
      );
      OpenChatApp.scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('$title: $body', maxLines: 2),
          duration: const Duration(seconds: 6),
        ),
      );
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

    if (auth.state == AuthState.authenticated &&
        !_appLocked &&
        (_pendingInviteToken != null || _pendingContactToken != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _drainPendingInviteLink();
        _drainPendingContactLink();
      });
    }

    if (auth.state == AuthState.authenticated && !_appLocked) {
      final userId = auth.currentUser?.id ?? '';
      final settings = context.watch<SettingsProvider>();
      if (!settings.isLoaded) {
        return Scaffold(
          body: LiquidMeshBackground(
            child: Center(
              child: GlassContainer(
                shape: const LiquidRoundedSuperellipse(borderRadius: 32),
                allowElevation: true,
                glowIntensity: 0.10,
                padding: const EdgeInsets.all(36),
                child: const GlassProgressIndicator.circular(
                  size: 36,
                  strokeWidth: 2.5,
                ),
              ),
            ),
          ),
        );
      }
      if (userId.isNotEmpty && !settings.hasViewedPrivacyOnboarding(userId)) {
        return PrivacyOnboardingScreen(
          onComplete: () {
            unawaited(settings.markPrivacyOnboardingViewed(userId));
          },
        );
      }
    }

    return switch (auth.state) {
      AuthState.unknown => Scaffold(
        body: LiquidMeshBackground(
          child: Center(
            child: GlassContainer(
              shape: const LiquidRoundedSuperellipse(borderRadius: 32),
              allowElevation: true,
              glowIntensity: 0.10,
              padding: const EdgeInsets.all(36),
              child: const GlassProgressIndicator.circular(
                size: 36,
                strokeWidth: 2.5,
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
  late final _pageController = PageController(initialPage: 0);

  /// Lets desktop keyboard shortcuts (Ctrl/Cmd+N) and the rail reach into the
  /// inbox for the new-conversation flow.
  final GlobalKey<ConversationsScreenState> _conversationsKey =
      GlobalKey<ConversationsScreenState>();

  // Bottom-bar search (Apple Music-style morphing pill). The query drives the
  // shared ChatSearchResultsView overlaid on the tab content.
  bool _searchActive = false;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // Content-aware bottom-bar brightness: the latest verdict from the glass
  // bar's content sampler (null until the first flip). Drives the pill's glyph
  // color so icons/labels stay legible over whatever scrolls underneath.
  Brightness? _barContentBrightness;

  @override
  void dispose() {
    _pageController.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onTabSelected(int i) {
    if (_searchActive) _setSearchActive(false);
    if (i == _tab) return;
    setState(() => _tab = i);
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  void _setSearchActive(bool active) {
    if (_searchActive == active) return;
    setState(() {
      _searchActive = active;
      if (!active) {
        _searchCtrl.clear();
        _searchQuery = '';
        _searchFocus.unfocus();
      }
    });
  }

  Future<void> _onSearchSelect(ChatSearchSelection selection) async {
    _setSearchActive(false);
    await handleChatSearchSelection(context, selection);
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    final settings = context.watch<SettingsProvider>();
    final desktop = isDesktopShell(context);

    // Chats is always present. Channels and Bots get their own tab only when
    // the user opts in; otherwise those conversations surface inside Chats.
    final screens = <Widget>[ConversationsScreen(key: _conversationsKey)];
    final scheme = Theme.of(context).colorScheme;
    final tabs = <GlassBottomBarTab>[
      GlassBottomBarTab(
        icon: const Icon(Icons.chat_bubble_outline),
        activeIcon: const Icon(Icons.chat_bubble),
        label: 'Chats',
        glowColor: scheme.primary,
      ),
    ];

    if (settings.channelsOwnTab) {
      screens.add(const ChannelListScreen());
      tabs.add(
        GlassBottomBarTab(
          icon: const Icon(Icons.campaign_outlined),
          activeIcon: const Icon(Icons.campaign),
          label: 'Channels',
          glowColor: scheme.tertiary,
        ),
      );
    }
    if (settings.botsOwnTab) {
      screens.add(const BotChatsScreen());
      tabs.add(
        GlassBottomBarTab(
          icon: const Icon(Icons.smart_toy_outlined),
          activeIcon: const Icon(Icons.smart_toy),
          label: 'Bots',
          glowColor: scheme.secondary,
        ),
      );
    }

    // Clamp in case a tab was just turned off while it was selected.
    if (_tab >= screens.length) _tab = 0;

    final tabContent = screens.length == 1
        // Single screen — no paging overhead.
        ? screens.first
        : PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            children: screens,
          );

    final searchOverlay = !_searchActive
        ? null
        // Search results replace the tab content while search is open.
        // removeBottom: the searching bar reports a taller size with the
        // keyboard up (package docs); without this the results list gets
        // double bottom padding.
        : Positioned.fill(
            child: MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      // The mobile shell types into the bottom bar's morphing
                      // pill; the desktop shell has no bottom bar, so search
                      // gets a proper inline field above the results.
                      if (desktop)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                          child: GlassTextField(
                            controller: _searchCtrl,
                            focusNode: _searchFocus,
                            placeholder: 'Search chats, messages, people',
                            autofocus: true,
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: const Icon(
                              Icons.close_rounded,
                              size: 20,
                            ),
                            onSuffixTap: () => _setSearchActive(false),
                            onChanged: (q) => setState(() => _searchQuery = q),
                          ),
                        ),
                      Expanded(
                        child: ChatSearchResultsView(
                          query: _searchQuery,
                          onSelect: (selection) =>
                              unawaited(_onSearchSelect(selection)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

    final body = Column(
      children: [
        if (user != null && user.isKeyExpired) _ExpiredKeyBanner(user: user),
        Expanded(child: Stack(children: [tabContent, ?searchOverlay])),
      ],
    );

    final Widget shell;
    if (desktop) {
      // Desktop shell: left navigation rail, no bottom bar. The rail carries
      // the tab destinations, search, and a settings shortcut.
      final chat = context.watch<ChatProvider>();
      var unread = 0;
      for (final c in chat.conversations) {
        unread += c.unreadCount;
      }
      shell = Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopNavRail(
              tabs: [
                for (var i = 0; i < tabs.length; i++)
                  DesktopNavRailTab(
                    icon: (tabs[i].icon as Icon).icon!,
                    activeIcon: (tabs[i].activeIcon as Icon).icon!,
                    label: tabs[i].label ?? '',
                    badgeCount: i == 0 ? unread : 0,
                  ),
              ],
              selectedIndex: _tab,
              onTabSelected: _onTabSelected,
              searchActive: _searchActive,
              onSearchTap: () => _setSearchActive(!_searchActive),
              onSettingsTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      );
    } else {
      // Content-aware glyph color (iOS 26 light/dark adaptation): the bar
      // reports Brightness.light when bright content scrolls under it
      // (→ dark glyphs) and Brightness.dark over dark content (→ light
      // glyphs). Before the first verdict we keep the theme's onSurface, so
      // the bar matches the ambient theme exactly as it did before.
      final Color glyph = switch (_barContentBrightness) {
        Brightness.light => const Color(0xFF1C1C1E),
        Brightness.dark => Colors.white,
        null => scheme.onSurface,
      };
      shell = GlassContentAwareScope(
        child: Scaffold(
          // Let content flow behind the translucent glass bar.
          extendBody: true,
          // Sample the tab content behind the bar so the pill's glyphs flip
          // to keep contrast over whatever scrolls underneath.
          body: GlassContentAwareContent(child: body),
          // The bar always shows: even single-tab setups host the search pill
          // (the iOS 26 searchable-bottom-bar pattern).
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: GlassSearchableBottomBar(
                tabs: tabs,
                selectedIndex: _tab,
                onTabSelected: _onTabSelected,
                isSearchActive: _searchActive,
                // Opt into content-aware brightness. The verdict drives
                // `glyph` above via onBrightnessChanged — the bar can't see
                // our Material-scheme icon colors, so we flip them ourselves.
                adaptiveBrightness: true,
                onBrightnessChanged: (b) =>
                    setState(() => _barContentBrightness = b),
                // The package's icon-color fallback is an unresolved
                // CupertinoColors.label, which paints light-mode black even in
                // dark themes — so wire icons to the resolved glyph instead.
                selectedIconColor: glyph,
                unselectedIconColor: glyph.withValues(alpha: 0.70),
                // The package default carries chromaticAberration: 0.3, whose
                // Impeller dispersion splits refracted light into an RGB
                // "rainbow" fringe along the pill's bottom edge when the
                // search bar is active. Same recipe, aberration zeroed.
                settings: LiquidGlassSettings(
                  thickness: 30,
                  blur: 3,
                  chromaticAberration: 0,
                  lightIntensity: 0.6,
                  refractiveIndex: 1.59,
                  saturation: 0.7,
                  ambientStrength: 1,
                  lightAngle: 0.75 * math.pi,
                  glassColor: const Color(0x3DFFFFFF),
                ),
                // Physics + glow for the iOS 26 feel.
                glowBlurRadius: 18,
                glowSpreadRadius: 2,
                glowOpacity: 0.55,
                barBorderRadius: 999,
                barHeight: 60,
                searchConfig: GlassSearchBarConfig(
                  hintText: 'Search',
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  autoFocusOnExpand: true,
                  onSearchToggle: _setSearchActive,
                  onChanged: (q) => setState(() => _searchQuery = q),
                  onCancelTap: () => _setSearchActive(false),
                  searchIconColor: glyph.withValues(alpha: 0.80),
                  micIconColor: glyph.withValues(alpha: 0.80),
                  textColor: glyph,
                  cursorColor: scheme.primary,
                  cancelButtonColor: scheme.primary,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Desktop keyboard shortcuts. CallbackShortcuts (not Shortcuts/Actions):
    // these fire from any focused descendant, including text fields' parents.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            _setSearchActive(!_searchActive),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            _setSearchActive(!_searchActive),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            _conversationsKey.currentState?.showNewConversation(),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
            _conversationsKey.currentState?.showNewConversation(),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchActive) _setSearchActive(false);
        },
      },
      child: FocusScope(autofocus: true, child: shell),
    );
  }
}

class _AppLockScreen extends StatefulWidget {
  final VoidCallback onUnlock;
  const _AppLockScreen({required this.onUnlock});

  @override
  State<_AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<_AppLockScreen> {
  final _pinController = TextEditingController();
  bool _pinError = false;
  bool _submitting = false;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submitPin() async {
    final pin = _pinController.text;
    if (pin.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _pinError = false;
    });
    final handler = appPinUnlockHandler;
    final ok = handler != null && await handler(pin);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      // A duress PIN reports success too — the screen must never reveal that
      // a second code exists, let alone which one was typed.
      _pinError = !ok;
      if (!ok) _pinController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: LiquidMeshBackground(
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: GlassContainer(
                shape: const LiquidRoundedSuperellipse(borderRadius: 40),
                allowElevation: true,
                glowIntensity: 0.08,
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
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
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
                    ValueListenableBuilder<bool>(
                      valueListenable: appPinConfiguredListenable,
                      builder: (context, pinConfigured, _) {
                        if (!pinConfigured) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: TextField(
                            key: const Key('app-lock-pin-field'),
                            controller: _pinController,
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              letterSpacing: 8,
                              fontWeight: FontWeight.w700,
                            ),
                            decoration: InputDecoration(
                              hintText: 'PIN',
                              errorText: _pinError ? 'Incorrect PIN' : null,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.arrow_forward_rounded),
                                onPressed: _submitting ? null : _submitPin,
                              ),
                            ),
                            onSubmitted: (_) => _submitPin(),
                          ),
                        );
                      },
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: GlassButtonWidget.icon(
                        onPressed: widget.onUnlock,
                        icon: const Icon(Icons.fingerprint_rounded, size: 20),
                        label: const Text('Unlock'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
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
      child: GlassCard(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        tint: scheme.error,
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.error.withValues(alpha: 0.22),
              ),
              child: Icon(
                Icons.lock_clock_outlined,
                color: scheme.error,
                size: 17,
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
