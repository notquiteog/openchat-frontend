import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-DM visual customization. Applies only to direct messages — group chats
/// and channels intentionally keep the default look so every member sees the
/// same thing.
class DmChatStyle {
  /// Solid background colour behind the message list (ARGB int). null = theme default.
  final int? backgroundColor;

  /// Local file path to a background image picked by the user. Takes precedence
  /// over [backgroundColor] when set. Stored as a path because it's a personal,
  /// device-local preference that never leaves the client.
  final String? backgroundImagePath;

  /// Colour of the current user's own outgoing bubbles (ARGB int). null = theme primary.
  final int? myBubbleColor;

  /// Colour of the other participant's incoming bubbles (ARGB int). null = theme surface.
  final int? theirBubbleColor;

  /// Corner radius applied to bubbles. Defaults to the app's standard 18.
  final double bubbleRadius;

  const DmChatStyle({
    this.backgroundColor,
    this.backgroundImagePath,
    this.myBubbleColor,
    this.theirBubbleColor,
    this.bubbleRadius = 18,
  });

  bool get isDefault =>
      backgroundColor == null &&
      backgroundImagePath == null &&
      myBubbleColor == null &&
      theirBubbleColor == null &&
      bubbleRadius == 18;

  DmChatStyle copyWith({
    int? backgroundColor,
    String? backgroundImagePath,
    int? myBubbleColor,
    int? theirBubbleColor,
    double? bubbleRadius,
    bool clearBackgroundColor = false,
    bool clearBackgroundImage = false,
    bool clearMyBubbleColor = false,
    bool clearTheirBubbleColor = false,
  }) =>
      DmChatStyle(
        backgroundColor: clearBackgroundColor
            ? null
            : (backgroundColor ?? this.backgroundColor),
        backgroundImagePath: clearBackgroundImage
            ? null
            : (backgroundImagePath ?? this.backgroundImagePath),
        myBubbleColor:
            clearMyBubbleColor ? null : (myBubbleColor ?? this.myBubbleColor),
        theirBubbleColor: clearTheirBubbleColor
            ? null
            : (theirBubbleColor ?? this.theirBubbleColor),
        bubbleRadius: bubbleRadius ?? this.bubbleRadius,
      );

  Map<String, dynamic> toJson() => {
        if (backgroundColor != null) 'bg': backgroundColor,
        if (backgroundImagePath != null) 'bg_img': backgroundImagePath,
        if (myBubbleColor != null) 'bubble': myBubbleColor,
        if (theirBubbleColor != null) 'their_bubble': theirBubbleColor,
        'radius': bubbleRadius,
      };

  factory DmChatStyle.fromJson(Map<String, dynamic> json) => DmChatStyle(
        backgroundColor: json['bg'] as int?,
        backgroundImagePath: json['bg_img'] as String?,
        myBubbleColor: json['bubble'] as int?,
        theirBubbleColor: json['their_bubble'] as int?,
        bubbleRadius: (json['radius'] as num?)?.toDouble() ?? 18,
      );
}

/// App-wide user preferences that persist across launches: the accent colour
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

  /// Firebase/APNs push notifications. Off by default (opt-in, privacy warning shown on enable).
  bool get pushNotificationsEnabled => _pushEnabled;

  /// Background WebSocket connection. Off by default (opt-in, battery warning shown on enable).
  bool get wsBackgroundEnabled => _wsBgEnabled;

  /// Show sender name + message preview in notifications. Off = generic "New message" text.
  bool get notificationSensitiveContent => _notifSensitive;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _seedColor = _prefs!.getInt(_kSeed) ?? defaultSeed;
    _channelsOwnTab = _prefs!.getBool(_kChannelsTab) ?? false;
    _botsOwnTab = _prefs!.getBool(_kBotsTab) ?? false;
    _pushEnabled = _prefs!.getBool(_kPushEnabled) ?? false;
    _wsBgEnabled = _prefs!.getBool(_kWsBgEnabled) ?? false;
    _notifSensitive = _prefs!.getBool(_kNotifSensitive) ?? false;
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
    notifyListeners();
    await _prefs?.setBool(_kPushEnabled, value);
  }

  Future<void> setWsBackgroundEnabled(bool value) async {
    _wsBgEnabled = value;
    notifyListeners();
    await _prefs?.setBool(_kWsBgEnabled, value);
  }

  Future<void> setNotificationSensitiveContent(bool value) async {
    _notifSensitive = value;
    notifyListeners();
    await _prefs?.setBool(_kNotifSensitive, value);
  }

  DmChatStyle dmStyleFor(String convID) {
    final raw = _prefs?.getString('$_kDmStylePrefix$convID');
    if (raw == null || raw.isEmpty) return const DmChatStyle();
    try {
      return DmChatStyle.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const DmChatStyle();
    }
  }

  Future<void> setDmStyle(String convID, DmChatStyle style) async {
    if (style.isDefault) {
      await _prefs?.remove('$_kDmStylePrefix$convID');
    } else {
      await _prefs?.setString(
          '$_kDmStylePrefix$convID', jsonEncode(style.toJson()));
    }
    notifyListeners();
  }
}
