import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'providers/auth_provider.dart';
import 'providers/call_provider.dart';
import 'providers/group_call_presence_provider.dart';
import 'providers/group_ring_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/key_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/smp_provider.dart';
import 'providers/stage_room_provider.dart';
import 'crypto/pgp_service.dart';
import 'services/api_service.dart';
import 'services/background_ws_service.dart';
import 'services/badge_service.dart';
import 'services/call_history_service.dart';
import 'services/call_quality_policy.dart';
import 'services/call_service.dart';
import 'services/call_signal_codec.dart';
import 'services/sfu_call_controller.dart';
import 'services/desktop_startup_service.dart';
import 'services/local_private_state_service.dart';
import 'services/mesh/nearby_mesh_service.dart';
import 'services/mls_service.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/network_service.dart';
import 'services/proxy_service.dart';
import 'services/secure_storage_service.dart';
import 'services/security_service.dart';
import 'services/websocket_service.dart';
import 'utils/global_notification_pause.dart';
import 'utils/local_conversation_preferences.dart';

/// Background FCM handler — runs in a separate isolate when the app is
/// terminated. Release pushes include a notification payload so the OS can show
/// them automatically. This handler remains a data-only fallback for incoming
/// calls so older servers still surface a local call notification.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // This isolate is by definition not the focused UI, but NotificationService
  // defaults to focused — without this, every notification below is suppressed
  // by the focus check while the app is terminated/backgrounded.
  NotificationService.setAppFocused(false);
  final type = message.data['type'];
  if (type == 'call_cancel') {
    // The call was answered/declined elsewhere or the caller hung up —
    // clear the displayed incoming-call notification.
    await NotificationService.init();
    await NotificationService.cancelIncomingCall();
    return;
  }
  if (message.notification == null && type == 'incoming_call') {
    // Per-chat mute / quiet hours apply to calls too (mentions-only doesn't —
    // it's a message-volume control, not a call block).
    final conversationId = await _resolveConversationId(message.data);
    if (!await _shouldRingForCall(conversationId)) return;
    await NotificationService.init();
    final isVideo = message.data['is_video'];
    final body = isVideo == null
        ? 'Incoming call'
        : 'Incoming ${isVideo == 'true' ? 'video' : 'voice'} call';
    await NotificationService.showIncomingCall(
      body: body,
      payload: jsonEncode(message.data),
    );
  } else if (message.notification == null &&
      (type == 'new_message' ||
          type == 'group_call' ||
          type == 'group_call_ring')) {
    final conversationId = await _resolveConversationId(message.data);
    // Ring-all (#9) honours per-chat mute too — same gate as a "Call started"
    // push (a muted group shouldn't ring everyone on a push-only device).
    if (!await _shouldShowMessageNotification(conversationId)) {
      return;
    }
    await NotificationService.init();
    var title = 'OpenChat';
    var body = switch (type) {
      'group_call' => 'Call started',
      'group_call_ring' => 'Incoming group call',
      _ => 'New message',
    };
    // group_call(_ring) bodies are fixed labels shown verbatim (no private
    // content). A new_message data-only push carries only an opaque route, so
    // resolve the sender / group name and decrypt the latest message locally
    // to honour the receiver's Show sender / Show message preview toggles.
    var showSender = true;
    var showPreview = true;
    if (type == 'new_message') {
      final visibility = await _currentNotificationVisibility();
      showSender = visibility.showSender;
      showPreview = visibility.showPreview;
      if (showSender || showPreview) {
        final display = await _terminatedMessageDisplay(
          conversationId,
          visibility,
        );
        title = display.$1;
        body = display.$2;
      }
    }
    final shown = await NotificationService.showMessage(
      conversationId: conversationId,
      title: title,
      body: body,
      showSender: showSender,
      showPreview: showPreview,
    );
    if (shown && type == 'new_message') {
      // Best-effort launcher badge bump while the app isn't running; the
      // next foreground recompute replaces it with the authoritative count.
      // Gated on the notification actually posting so the badge never counts
      // messages the user was never alerted to.
      await BadgeService.incrementFromBackground();
    }
  }
}

Future<bool> _shouldRingForCall(String conversationId) async {
  try {
    final privateState = await LocalPrivateStateService().readState();
    final notificationSettings = decodePrivateNotificationSettings(
      privateState[privateStateNotificationSettingsKey],
    );
    final globallyPaused = isGloballyPausedAt(
      DateTime.now(),
      pausedUntilMs: notificationSettings.notificationsPausedUntilMs,
      quietStartMinute: notificationSettings.globalQuietHoursStartMinute,
      quietEndMinute: notificationSettings.globalQuietHoursEndMinute,
    );
    if (globallyPaused && !notificationSettings.pauseAllowsCalls) {
      return false;
    }
    final preferences = decodePrivateConversationNotificationPreferences(
      privateState[privateStateConversationNotificationPreferencesKey],
    );
    final pref = preferences[conversationId];
    if (pref == null) return true;
    final now = DateTime.now();
    return !pref.isMutedAt(now) && !pref.isQuietAt(now);
  } catch (_) {
    return true;
  }
}

/// Resolves a push payload to a conversation id. Push payloads carry only an
/// opaque `route` token (the real conversation id never reaches FCM/APNs); this
/// background isolate maps it back via the persisted route map. Falls back to a
/// generic id when the route is unknown (still shows a notification).
Future<String> _resolveConversationId(Map<String, dynamic> data) async {
  final explicit = data['conversation_id'] as String?;
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final route = data['route'] as String?;
  if (route == null || route.isEmpty) return 'push';
  try {
    final state = await LocalPrivateStateService().readState();
    final map = decodePushRouteMap(state[privateStatePushRouteMapKey]);
    return map[route] ?? 'push';
  } catch (_) {
    return 'push';
  }
}

Future<bool> _shouldShowMessageNotification(String conversationId) async {
  final privateState = await LocalPrivateStateService().readState();
  final notificationSettings = decodePrivateNotificationSettings(
    privateState[privateStateNotificationSettingsKey],
  );
  if (isGloballyPausedAt(
    DateTime.now(),
    pausedUntilMs: notificationSettings.notificationsPausedUntilMs,
    quietStartMinute: notificationSettings.globalQuietHoursStartMinute,
    quietEndMinute: notificationSettings.globalQuietHoursEndMinute,
  )) {
    return false;
  }
  final preferences = decodePrivateConversationNotificationPreferences(
    privateState[privateStateConversationNotificationPreferencesKey],
  );
  return shouldNotifyForConversation(
    conversationId: conversationId,
    preferences: preferences,
  );
}

/// The receiver's notification content-visibility preferences, read from
/// encrypted local state (the only source available to this terminated-app
/// isolate). Defaults to hidden on any read failure.
Future<NotificationContentVisibility> _currentNotificationVisibility() async {
  try {
    final state = await LocalPrivateStateService().readState();
    final settings = decodePrivateNotificationSettings(
      state[privateStateNotificationSettingsKey],
    );
    return NotificationContentVisibility(
      showSender: settings.showSender,
      showPreview: settings.showPreview,
    );
  } catch (_) {
    return NotificationContentVisibility.hidden;
  }
}

/// Resolves the (ungated) title + body for a terminated-app new-message push by
/// reading the group/channel name from local state and fetching+decrypting the
/// latest message. The caller passes the two visibility flags to
/// [NotificationService.showMessage], which applies the actual gate — so this
/// only does the work the flags require and degrades to ("OpenChat", "New
/// message") on any failure (network, locked keyring, FFI unavailable here).
Future<(String, String)> _terminatedMessageDisplay(
  String conversationId,
  NotificationContentVisibility visibility,
) async {
  var title = 'OpenChat';
  var body = 'New message';
  try {
    final state = await LocalPrivateStateService().readState();
    final meta = decodeConversationMeta(
      state[privateStateConversationMetaKey],
    )[conversationId];
    final isGroupOrChannel = meta?.isGroupOrChannel ?? false;
    final groupName = meta?.name.trim() ?? '';

    String? sender;
    String? preview;
    final storage = SecureStorageService();
    final token = await storage.getAccessToken();
    if (token != null && token.isNotEmpty) {
      final messages = await ApiService(
        storage,
      ).getMessages(conversationId, limit: 1);
      if (messages.isNotEmpty) {
        // Server orders messages created_at DESC, so the first is the newest —
        // the one this push is about.
        final msg = messages.first;
        sender = msg.sender?.username;
        if (visibility.showPreview && msg.encryptedPayload.isNotEmpty) {
          final privateKey = await storage.getPrivateKey();
          if (privateKey != null && privateKey.isNotEmpty) {
            final raw = await PgpService.decrypt(
              encryptedArmor: msg.encryptedPayload,
              privateKeyArmored: privateKey,
            );
            if (raw.isNotEmpty) {
              msg.setDecryptedContent(raw);
              preview = msg.notificationPreview;
            }
          }
        }
      }
    }

    // Title is identity — only resolve it when Show sender is on (matches the
    // background-WS path; showMessage would gate it away otherwise).
    if (visibility.showSender) {
      if (isGroupOrChannel && groupName.isNotEmpty) {
        title = groupName;
      } else if (sender != null && sender.isNotEmpty) {
        title = '@$sender';
      }
    }
    final trimmedPreview = preview?.trim() ?? '';
    if (trimmedPreview.isNotEmpty) {
      body = (isGroupOrChannel && sender != null && sender.isNotEmpty)
          ? '@$sender: $trimmedPreview'
          : trimmedPreview;
    }
  } catch (_) {
    // Fall back to generic text — never crash the background isolate.
  }
  return (title, body);
}

/// Runs one pre-runApp init step, downgrading any failure to a log line.
Future<void> _guardStartupStep(
  String name,
  Future<void> Function() step,
) async {
  try {
    await step();
  } catch (e) {
    debugPrint('Startup step "$name" failed (continuing degraded): $e');
  }
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Linux/Windows need a just_audio platform backend for voice notes and tones.
  JustAudioMediaKit.ensureInitialized();
  // Pre-warm the liquid glass shader pipeline before any UI is painted.
  // On Impeller (iOS/Android) this unlocks real refraction + chromatic
  // aberration; on Skia it primes the lightweight fragment shader.
  await LiquidGlassWidgets.initialize();
  final startMinimized = args.contains(desktopStartMinimizedArg);
  await DesktopStartupService.startTray(startMinimized: startMinimized);
  // Every pre-runApp step below talks to platform plugins. None of them is
  // worth a black screen: if plugin registration broke (a release build once
  // shipped where one plugin's NoClassDefFoundError aborted the whole
  // GeneratedPluginRegistrant), an unhandled MissingPluginException here used
  // to kill main() before runApp and the app sat on a black window forever.
  // Run the app degraded instead — the failures are logged and every feature
  // retries through its own init path.
  await _guardStartupStep('push background handler', () async {
    // Register Firebase background message handler before runApp so the
    // messaging plugin can dispatch messages when the app is terminated.
    // No-op when Firebase credentials are placeholders or platform unsupported.
    await PushNotificationService.registerBackgroundHandler(
      _firebaseBackgroundHandler,
    );
  });
  await _guardStartupStep('background WS configure', () async {
    // Configure the background WS service isolate; must run before any UI.
    await BackgroundWsService.configure();
  });
  // Keep the background WS isolate's credentials fresh: every persisted token
  // refresh is pushed into the running service (it never refreshes tokens
  // itself — a double refresh would race and invalidate the session).
  ApiService.onAccessTokenRefreshed = BackgroundWsService.updateToken;
  await _guardStartupStep('screen security', () async {
    // Apply the persisted screenshot-prevention setting as early as possible so
    // FLAG_SECURE / the iOS secure layer is in place before the first frame.
    await SecureStorageService().getScreenSecurity().then(
      SecurityService.instance.setGlobalSecure,
    );
  });
  await _guardStartupStep('proxy load', () async {
    // Install the proxy (HttpOverrides) BEFORE any HTTP/WS client is built so
    // all traffic is routed from the first request.
    await ProxyService.instance.load(SecureStorageService());
  });
  runApp(
    LiquidGlassWidgets.wrap(
      // Adaptive quality: benchmarks the device on first launch and adjusts
      // shader complexity (premium → standard → minimal) to keep 60 fps.
      adaptiveQuality: true,
      child: const _Providers(),
    ),
  );
}

class _Providers extends StatelessWidget {
  const _Providers();

  @override
  Widget build(BuildContext context) {
    final storage = SecureStorageService();
    final api = ApiService(storage);
    final ws = WebSocketService(storage);
    final mls = MlsService(storage);
    final callService = CallService(
      ws,
      api,
      signalCodec: PrivacyCallSignalCodec(api, storage, mls),
      storage: storage,
    );
    final callHistory = CallHistoryService(storage);

    return MultiProvider(
      providers: [
        Provider<SecureStorageService>.value(value: storage),
        ChangeNotifierProvider<NetworkService>(
          create: (_) => NetworkService()..init(),
        ),
        Provider<CallHistoryService>.value(value: callHistory),
        Provider<ApiService>.value(value: api),
        Provider<MlsService>.value(value: mls),
        ChangeNotifierProvider<WebSocketService>.value(value: ws),
        Provider<CallService>.value(value: callService),
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        // Pass the shared call-history instance so logout's wipe also resets
        // its cached at-rest key material (not just the rows on disk).
        ChangeNotifierProvider(
          create: (_) =>
              AuthProvider(api, storage, callHistoryService: callHistory),
        ),
        ChangeNotifierProvider(create: (_) => KeyProvider(storage)),
        // SettingsProvider must be registered before ChatProvider so the
        // create callback can read it via ctx.read<SettingsProvider>().
        ChangeNotifierProvider(
          create: (ctx) => ChatProvider(
            api,
            storage,
            ws,
            ctx.read<SettingsProvider>(),
            mls,
            ctx.read<NetworkService>(),
          ),
        ),
        ChangeNotifierProxyProvider<ChatProvider, SmpProvider>(
          create: (ctx) =>
              SmpProvider(chat: ctx.read<ChatProvider>(), storage: storage),
          update: (_, _, previous) => previous!,
        ),
        // App-level so the radio can outlive the Nearby screen (keep-alive
        // opt-in) and the DM header can show live mesh presence. Lazy: the
        // constructor is inert; nothing touches Bluetooth until start().
        ChangeNotifierProvider<NearbyMeshService>(
          create: (ctx) => NearbyMeshService(
            storage: storage,
            onEnvelope: (envelope, fingerprint) => ctx
                .read<ChatProvider>()
                .ingestMeshMessage(envelope, fingerprint),
            envelopesForPeer: (fingerprint) => ctx
                .read<ChatProvider>()
                .meshEnvelopesForFingerprint(fingerprint),
            // #26: encrypted attachment transfer over LAN.
            onAttachment: (envelope, fingerprint) => ctx
                .read<ChatProvider>()
                .ingestMeshAttachment(envelope, fingerprint),
            attachmentsForPeer: (fingerprint) => ctx
                .read<ChatProvider>()
                .meshAttachmentsForFingerprint(fingerprint),
            contactNameForFingerprint: (fingerprint) {
              final chat = ctx.read<ChatProvider>();
              final convID = chat.dmConversationIdForFingerprint(fingerprint);
              if (convID == null) return null;
              return chat.conversations
                  .where((c) => c.id == convID)
                  .firstOrNull
                  ?.displayName('');
            },
            onEnvelopeAcked: (nonce, accepted) {
              if (accepted) {
                ctx.read<ChatProvider>().markMeshDelivered(nonce);
              }
            },
            outboxSignal: ctx.read<ChatProvider>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) => CallProvider(
            callService,
            callHistory: callHistory,
            settings: ctx.read<SettingsProvider>(),
            network: ctx.read<NetworkService>(),
          ),
        ),
        // SFU call ends are logged through CallProvider so the device call
        // history covers group SFU calls too (sfu = true entries).
        ChangeNotifierProvider(
          create: (ctx) => SfuCallController(
            api,
            ws,
            onCallEnded: ctx.read<CallProvider>().recordSfuCallEnded,
            qualityPolicy: () {
              final settings = ctx.read<SettingsProvider>();
              final net = ctx.read<NetworkService>().current;
              final forceAudioOnly = settings.voiceOnlyForNetwork(net);
              if (settings.dataSaverActive(net)) {
                return CallQualityPolicy.dataSaver(
                  forceAudioOnly: forceAudioOnly,
                );
              }
              return CallQualityPolicy.normal(forceAudioOnly: forceAudioOnly);
            },
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => StageRoomProvider(api, ws, storage),
        ),
        ChangeNotifierProvider(
          create: (_) => GroupCallPresenceProvider(ws, api),
        ),
        ChangeNotifierProvider(create: (_) => GroupRingProvider(ws)),
      ],
      child: const OpenChatApp(),
    );
  }
}
