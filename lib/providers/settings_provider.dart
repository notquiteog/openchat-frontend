import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-chat visual customization.
class ChatStyle {
  /// Solid background color behind the message list (ARGB int). null = theme default.
  final int? backgroundColor;

  /// Local file path to a background image picked by the user. Takes precedence
  /// over [backgroundColor] when set. Stored as a path because it's a personal,
  /// device-local preference that never leaves the client.
  final String? backgroundImagePath;

  /// Color of the current user's own outgoing bubbles (ARGB int). null = theme primary.
  final int? myBubbleColor;

  /// Corner radius applied to bubbles. Defaults to the app's standard 18.
  final double bubbleRadius;

  const ChatStyle({
    this.backgroundColor,
    this.backgroundImagePath,
    this.myBubbleColor,
    this.bubbleRadius = 18,
  });

  bool get isDefault =>
      backgroundColor == null &&
      backgroundImagePath == null &&
      myBubbleColor == null &&
      bubbleRadius == 18;

  ChatStyle copyWith({
    int? backgroundColor,
    String? backgroundImagePath,
    int? myBubbleColor,
    double? bubbleRadius,
    bool clearBackgroundColor = false,
    bool clearBackgroundImage = false,
    bool clearMyBubbleColor = false,
  }) => ChatStyle(
    backgroundColor: clearBackgroundColor
        ? null
        : (backgroundColor ?? this.backgroundColor),
    backgroundImagePath: clearBackgroundImage
        ? null
        : (backgroundImagePath ?? this.backgroundImagePath),
    myBubbleColor: clearMyBubbleColor
        ? null
        : (myBubbleColor ?? this.myBubbleColor),
    bubbleRadius: bubbleRadius ?? this.bubbleRadius,
  );

  Map<String, dynamic> toJson() => {
    if (backgroundColor != null) 'bg': backgroundColor,
    if (backgroundImagePath != null) 'bg_img': backgroundImagePath,
    if (myBubbleColor != null) 'bubble': myBubbleColor,
    'radius': bubbleRadius,
  };

  factory ChatStyle.fromJson(Map<String, dynamic> json) => ChatStyle(
    backgroundColor: json['bg'] as int?,
    backgroundImagePath: json['bg_img'] as String?,
    myBubbleColor: json['bubble'] as int?,
    bubbleRadius: (json['radius'] as num?)?.toDouble() ?? 18,
  );
}

typedef DmChatStyle = ChatStyle;

/// App-wide user preferences that persist across launches: the accent color
/// used to seed the Material theme, whether Channels and Bots get their own
/// navigation tabs, per-DM chat styling, and notification settings.
class SettingsProvider extends ChangeNotifier {
  static const _kSeed = 'app_seed_color';
  static const _kChannelsTab = 'channels_own_tab';
  static const _kBotsTab = 'bots_own_tab';
  static const _kDmStylePrefix = 'dm_style_';
  static const _kPushEnabled = 'push_notifications_enabled';
  static const _kWsBgEnabled = 'ws_background_enabled';
  static const _kNotifSensitive = 'notification_sensitive_content';

  /// OpenChat brand blue — the historical default seed.
  static const int defaultSeed = 0xFF3D5AFE;

  SharedPreferences? _prefs;
  Future<void>? _loadFuture;
  bool _loaded = false;

  int _seedColor = defaultSeed;
  bool _channelsOwnTab = false;
  bool _botsOwnTab = false;
  bool _pushEnabled = false;
  bool _wsBgEnabled = false;
  bool _notifSensitive = false;

  int get seedColorValue => _seedColor;
  Color get seedColor => Color(_seedColor);
  bool get channelsOwnTab => _channelsOwnTab;
  bool get botsOwnTab => _botsOwnTab;
  bool get isLoaded => _loaded;

  /// Firebase/APNs push notifications. Off by default (opt-in, privacy warning shown on enable).
  bool get pushNotificationsEnabled => _pushEnabled;

  /// Background WebSocket connection. Off by default (opt-in, battery warning shown on enable).
  bool get wsBackgroundEnabled => _wsBgEnabled;

  /// Show sender name + message preview in notifications. Off = generic "New message" text.
  bool get notificationSensitiveContent => _notifSensitive;

  Future<void> load() {
    _loadFuture ??= _load();
    return _loadFuture!;
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    _seedColor = _prefs!.getInt(_kSeed) ?? defaultSeed;
    _channelsOwnTab = _prefs!.getBool(_kChannelsTab) ?? false;
    _botsOwnTab = _prefs!.getBool(_kBotsTab) ?? false;
    _pushEnabled = _prefs!.getBool(_kPushEnabled) ?? false;
    _wsBgEnabled = _prefs!.getBool(_kWsBgEnabled) ?? false;
    if (_pushEnabled && _wsBgEnabled) {
      // Legacy state guard: never allow both channels to stay enabled.
      _wsBgEnabled = false;
      await _prefs!.setBool(_kWsBgEnabled, false);
    }
    _notifSensitive = _prefs!.getBool(_kNotifSensitive) ?? false;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setSeedColor(Color color) async {
    _seedColor = color.toARGB32();
    notifyListeners();
    await _prefs?.setInt(_kSeed, _seedColor);
  }

  Future<void> resetSeedColor() => setSeedColor(const Color(defaultSeed));

  Future<void> setChannelsOwnTab(bool value) async {
    _channelsOwnTab = value;
    notifyListeners();
    await _prefs?.setBool(_kChannelsTab, value);
  }

  Future<void> setBotsOwnTab(bool value) async {
    _botsOwnTab = value;
    notifyListeners();
    await _prefs?.setBool(_kBotsTab, value);
  }

  Future<void> setPushNotificationsEnabled(bool value) async {
    _pushEnabled = value;
    if (value) {
      _wsBgEnabled = false;
    }
    notifyListeners();
    await _prefs?.setBool(_kPushEnabled, value);
    if (value) {
      await _prefs?.setBool(_kWsBgEnabled, false);
    }
  }

  Future<void> setWsBackgroundEnabled(bool value) async {
    _wsBgEnabled = value;
    if (value) {
      _pushEnabled = false;
    }
    notifyListeners();
    await _prefs?.setBool(_kWsBgEnabled, value);
    if (value) {
      await _prefs?.setBool(_kPushEnabled, false);
    }
  }

  Future<void> setNotificationSensitiveContent(bool value) async {
    _notifSensitive = value;
    notifyListeners();
    await _prefs?.setBool(_kNotifSensitive, value);
  }

  ChatStyle chatStyleFor(String convID) {
    final raw = _prefs?.getString('$_kDmStylePrefix$convID');
    if (raw == null || raw.isEmpty) return const ChatStyle();
    try {
      return ChatStyle.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ChatStyle();
    }
  }

  DmChatStyle dmStyleFor(String convID) => chatStyleFor(convID);

  Future<void> setChatStyle(String convID, ChatStyle style) async {
    if (style.isDefault) {
      await _prefs?.remove('$_kDmStylePrefix$convID');
    } else {
      await _prefs?.setString(
        '$_kDmStylePrefix$convID',
        jsonEncode(style.toJson()),
      );
    }
    notifyListeners();
  }

  Future<void> setDmStyle(String convID, DmChatStyle style) =>
      setChatStyle(convID, style);
}
