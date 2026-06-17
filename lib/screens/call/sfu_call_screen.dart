import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:provider/provider.dart';

import '../../services/sfu_call_controller.dart';
import '../../services/sfu_call_reactions.dart';
import '../../widgets/connection_quality_bars.dart';
import '../../widgets/glass.dart';
import 'call_glass.dart';

List<int> sfuFocusOrder({
  required List<({String sid, double audioLevel, bool isSpeaking})> tiles,
  String? pinnedSid,
  bool autoFocus = false,
}) {
  final indexes = List<int>.generate(tiles.length, (index) => index);
  if (indexes.length <= 1) return indexes;

  var focusIndex = -1;
  if (pinnedSid != null) {
    focusIndex = indexes.indexWhere((index) => tiles[index].sid == pinnedSid);
  }
  if (focusIndex < 0 && autoFocus) {
    var bestLevel = -1.0;
    for (final index in indexes) {
      final tile = tiles[index];
      if (!tile.isSpeaking) continue;
      if (tile.audioLevel > bestLevel) {
        bestLevel = tile.audioLevel;
        focusIndex = index;
      }
    }
  }
  if (focusIndex < 0) return indexes;
  return [focusIndex, ...indexes.where((index) => index != focusIndex)];
}

/// Full-screen UI for a LiveKit SFU group call, in the same iOS-26 / FaceTime
/// Liquid Glass style as the P2P CallScreen (shared widgets from
/// call_glass.dart). Reads [SfuCallController] and pops itself when the call
/// ends. During a live video call, tapping the stage hides the chrome.
class SfuCallScreen extends StatefulWidget {
  const SfuCallScreen({super.key});

  @override
  State<SfuCallScreen> createState() => _SfuCallScreenState();
}

class _SfuCallScreenState extends State<SfuCallScreen> {
  bool _chromeVisible = true;
  StreamSubscription<SfuCallReaction>? _reactionSub;
  SfuCallController? _subscribedSfu;
  final Map<String, List<SfuCallReaction>> _tileReactions = {};
  String? _pinnedSid;
  bool _autoFocus = false;
  String? _focusedSid;
  Timer? _focusDebounce;

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  bool get _supportsScreenShare =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool _participantHasLiveVideo(lk.Participant p) {
    final pubs = p.videoTrackPublications;
    if (pubs.isEmpty) return false;
    final pub = pubs.first;
    return pub.track is lk.VideoTrack && !pub.muted;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sfu = context.read<SfuCallController>();
    if (identical(_subscribedSfu, sfu)) return;
    _reactionSub?.cancel();
    _tileReactions.clear();
    _subscribedSfu = sfu;
    _reactionSub = sfu.reactionAnnouncements.listen(_onReaction);
  }

  @override
  void dispose() {
    _reactionSub?.cancel();
    _focusDebounce?.cancel();
    super.dispose();
  }

  void _togglePin(String sid) {
    setState(() {
      final clearing = _pinnedSid == sid;
      _pinnedSid = clearing ? null : sid;
      if (!clearing) {
        _autoFocus = false;
        _focusedSid = null;
        _focusDebounce?.cancel();
      }
    });
  }

  void _toggleAutoFocus() {
    setState(() {
      _autoFocus = !_autoFocus;
      _pinnedSid = null;
      if (!_autoFocus) {
        _focusedSid = null;
        _focusDebounce?.cancel();
      }
    });
  }

  void _syncAutoFocusCandidate(List<lk.Participant> participants) {
    if (!_autoFocus || _pinnedSid != null || participants.length <= 1) return;
    String? candidateSid;
    var bestLevel = -1.0;
    for (final participant in participants) {
      if (!participant.isSpeaking) continue;
      if (participant.audioLevel > bestLevel) {
        bestLevel = participant.audioLevel;
        candidateSid = participant.sid;
      }
    }
    if (candidateSid == _focusedSid) {
      _focusDebounce?.cancel();
      return;
    }
    _focusDebounce?.cancel();
    _focusDebounce = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _focusedSid = candidateSid);
    });
  }

  void _onReaction(SfuCallReaction reaction) {
    if (!mounted) return;
    setState(() {
      final next = <SfuCallReaction>[
        ...?_tileReactions[reaction.identity],
        reaction,
      ];
      _tileReactions[reaction.identity] = next.length > 4
          ? next.sublist(next.length - 4)
          : next;
    });
  }

  void _removeReaction(SfuCallReaction reaction) {
    if (!mounted) return;
    setState(() {
      final current = _tileReactions[reaction.identity];
      if (current == null) return;
      final next = current.where((r) => r.id != reaction.id).toList();
      if (next.isEmpty) {
        _tileReactions.remove(reaction.identity);
      } else {
        _tileReactions[reaction.identity] = next;
      }
    });
  }

  Future<void> _showReactionPicker(SfuCallController sfu) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Center(
              heightFactor: 1,
              child: GlassContainer(
                shape: const LiquidRoundedSuperellipse(borderRadius: 34),
                useOwnLayer: true,
                quality: GlassQuality.standard,
                padding: const EdgeInsets.all(14),
                child: AdaptiveLiquidGlassLayer(
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final emoji in sfuCallReactionEmojiAllowlist)
                        GlassButton.custom(
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(sfu.sendReaction(emoji));
                          },
                          width: 52,
                          height: 52,
                          shape: const LiquidOval(),
                          // Group into the sheet's shared glass layer rather than
                          // one backdrop capture per emoji (8 < 16-shape ceiling).
                          useOwnLayer: false,
                          quality: GlassQuality.standard,
                          child: Center(
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 26),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sfu = context.watch<SfuCallController>();
    if (!sfu.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
      });
      return const SizedBox.shrink();
    }

    final participants = sfu.participants;
    _syncAutoFocusCandidate(participants);
    final requestedFocusSid = _pinnedSid ?? (_autoFocus ? _focusedSid : null);
    final focusSidExists =
        requestedFocusSid != null &&
        participants.any((participant) => participant.sid == requestedFocusSid);
    final focusSid = focusSidExists ? requestedFocusSid : null;
    final orderedIndexes = sfuFocusOrder(
      tiles: [
        for (final participant in participants)
          (
            sid: participant.sid,
            audioLevel: participant.audioLevel,
            isSpeaking: participant.isSpeaking,
          ),
      ],
      pinnedSid: focusSid,
    );
    final orderedParticipants = [
      for (final index in orderedIndexes) participants[index],
    ];
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    final desktopLayout = width >= 720;
    final compactLayout = width < 430;
    final buttonSize = compactLayout ? 52.0 : 56.0;
    final connecting = sfu.isConnecting && participants.length <= 1;
    final hasLiveVideo =
        sfu.isVideo && participants.any(_participantHasLiveVideo);
    final chromeHideable = hasLiveVideo;
    final showChrome = !chromeHideable || _chromeVisible;

    final secondary = <Widget>[
      CallControlButton(
        icon: sfu.isMicEnabled ? Icons.mic : Icons.mic_off,
        label: 'Mute',
        active: !sfu.isMicEnabled,
        activeColor: callEndColor,
        size: buttonSize,
        onTap: () => sfu.toggleMic(),
      ),
      if (sfu.isVideo)
        CallControlButton(
          icon: sfu.isCameraEnabled ? Icons.videocam : Icons.videocam_off,
          label: 'Camera',
          active: !sfu.isCameraEnabled,
          activeColor: callEndColor,
          size: buttonSize,
          onTap: () => sfu.toggleCamera(),
        ),
      if (sfu.isVideo && _isMobile)
        CallControlButton(
          icon: Icons.cameraswitch_rounded,
          label: 'Flip',
          size: buttonSize,
          onTap: () => sfu.switchCamera(),
        ),
      if (_supportsScreenShare)
        CallControlButton(
          icon: sfu.isScreenSharing
              ? Icons.stop_screen_share
              : Icons.screen_share,
          label: 'Share',
          active: sfu.isScreenSharing,
          activeColor: callAnswerColor,
          size: buttonSize,
          onTap: () => sfu.toggleScreenShare(),
        ),
      if (participants.length > 2)
        CallControlButton(
          icon: _autoFocus
              ? Icons.center_focus_strong_rounded
              : Icons.center_focus_weak_rounded,
          label: 'Focus',
          active: _autoFocus,
          activeColor: callAnswerColor,
          size: buttonSize,
          onTap: _toggleAutoFocus,
        ),
      CallControlButton(
        icon: Icons.add_reaction_outlined,
        label: 'React',
        size: buttonSize,
        onTap: () => _showReactionPicker(sfu),
      ),
      CallControlButton(
        icon: Icons.back_hand_rounded,
        label: 'Raise',
        active: sfu.selfRaisedHand,
        activeColor: callAnswerColor,
        size: buttonSize,
        onTap: () => sfu.toggleRaiseHand(),
      ),
    ];

    final topInset = mq.padding.top + 84;
    final bottomInset = mq.padding.bottom + (desktopLayout ? 188.0 : 208.0);
    final spotlight = focusSid != null && orderedParticipants.length > 1;

    final stage = connecting
        ? _Connecting(title: sfu.title ?? 'Group call')
        : spotlight
        ? _SfuSpotlight(
            participants: orderedParticipants,
            isVideo: sfu.isVideo,
            focusSid: focusSid,
            autoFocused: _autoFocus && _pinnedSid == null,
            reactionsByIdentity: _tileReactions,
            raisedHands: sfu.raisedHands,
            onReactionCompleted: _removeReaction,
            onTapParticipant: _togglePin,
            topInset: topInset,
            bottomInset: bottomInset,
          )
        : _SfuGrid(
            participants: orderedParticipants,
            isVideo: sfu.isVideo,
            focusSid: focusSid,
            autoFocused: _autoFocus && _pinnedSid == null,
            reactionsByIdentity: _tileReactions,
            raisedHands: sfu.raisedHands,
            onReactionCompleted: _removeReaction,
            onTapParticipant: _togglePin,
            topInset: topInset,
            bottomInset: bottomInset,
          );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (!hasLiveVideo)
            Positioned.fill(
              child: CallBackground(username: sfu.title ?? 'Group call'),
            ),

          Positioned.fill(
            child: chromeHideable
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleChrome,
                    child: stage,
                  )
                : stage,
          ),

          // ── Edge scrims (control legibility over bright video) ──────────────
          if (hasLiveVideo) ...[
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 168,
              child: AnimatedSlide(
                offset: showChrome ? Offset.zero : const Offset(0, -1),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
                child: const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x80000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 260,
              child: AnimatedSlide(
                offset: showChrome ? Offset.zero : const Offset(0, 1),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
                child: const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0x8C000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],

          // ── Header ─────────────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              offset: showChrome ? Offset.zero : const Offset(0, -1),
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: IgnorePointer(
                ignoring: !showChrome,
                child: SafeArea(
                  bottom: false,
                  child: _SfuHeader(
                    title: sfu.title ?? 'Group call',
                    connecting: sfu.isConnecting,
                    reconnecting: sfu.isReconnecting,
                    count: orderedParticipants.length,
                    mediaE2EE: sfu.isMediaE2EE,
                  ),
                ),
              ),
            ),
          ),

          // ── Controls ───────────────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              offset: showChrome ? Offset.zero : const Offset(0, 1.3),
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: IgnorePointer(
                ignoring: !showChrome,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      desktopLayout ? 40 : 16,
                      8,
                      desktopLayout ? 40 : 16,
                      16,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: desktopLayout ? 560 : double.infinity,
                        ),
                        child: CallControlsPanel(
                          secondaryControls: secondary,
                          onHangup: () => sfu.leave(),
                          buttonSize: buttonSize,
                          desktopLayout: desktopLayout,
                          compactLayout: compactLayout,
                          endLabel: 'Leave',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SfuHeader extends StatelessWidget {
  const _SfuHeader({
    required this.title,
    required this.connecting,
    required this.reconnecting,
    required this.count,
    this.mediaE2EE = false,
  });

  final String title;
  final bool connecting;
  final bool reconnecting;
  final int count;
  final bool mediaE2EE;

  @override
  Widget build(BuildContext context) {
    final subtitle = reconnecting
        ? 'Reconnecting…'
        : connecting
        ? 'Connecting…'
        : '$count ${count == 1 ? 'person' : 'people'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          // Glass status capsule (people count / connecting), plus the media
          // E2EE lock — frames are encrypted with the conversation's call key
          // and the SFU only ever routes ciphertext.
          GlassContainer(
            shape: const LiquidRoundedSuperellipse(borderRadius: 999),
            useOwnLayer: true,
            quality: GlassQuality.standard,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            child: Row(
              key: reconnecting ? const Key('sfu-reconnecting-pill') : null,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  reconnecting || connecting
                      ? Icons.cloud_sync_rounded
                      : Icons.groups_rounded,
                  color: Colors.white70,
                  size: 14,
                ),
                const SizedBox(width: 6),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (mediaE2EE) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Media is end-to-end encrypted',
                    child: Icon(
                      Icons.lock_rounded,
                      color: Colors.greenAccent.shade100,
                      size: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulsingGlowAvatar(username: title, size: 132),
          const SizedBox(height: 30),
          const Text(
            'Connecting…',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SfuGrid extends StatelessWidget {
  const _SfuGrid({
    required this.participants,
    required this.isVideo,
    required this.focusSid,
    required this.autoFocused,
    required this.reactionsByIdentity,
    required this.raisedHands,
    required this.onReactionCompleted,
    required this.onTapParticipant,
    this.topInset = 96,
    this.bottomInset = 208,
  });

  final List<lk.Participant> participants;
  final bool isVideo;
  final String? focusSid;
  final bool autoFocused;
  final Map<String, List<SfuCallReaction>> reactionsByIdentity;
  final Set<String> raisedHands;
  final ValueChanged<SfuCallReaction> onReactionCompleted;
  final ValueChanged<String> onTapParticipant;
  final double topInset;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final n = participants.length;
    final width = MediaQuery.sizeOf(context).width;
    final cols = n <= 1
        ? 1
        : n <= 4
        ? 2
        : (width >= 900 ? 4 : 3);
    return GridView.builder(
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(12, topInset, 12, bottomInset),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 0.82,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: n,
      itemBuilder: (_, i) {
        final participant = participants[i];
        return _SfuTile(
          participant: participant,
          isVideo: isVideo,
          focused: participant.sid == focusSid,
          autoFocused: autoFocused && participant.sid == focusSid,
          reactions: reactionsByIdentity[participant.identity] ?? const [],
          raisedHand: raisedHands.contains(participant.identity),
          onReactionCompleted: onReactionCompleted,
          onTap: () => onTapParticipant(participant.sid),
        );
      },
    );
  }
}

class _SfuSpotlight extends StatelessWidget {
  const _SfuSpotlight({
    required this.participants,
    required this.isVideo,
    required this.focusSid,
    required this.autoFocused,
    required this.reactionsByIdentity,
    required this.raisedHands,
    required this.onReactionCompleted,
    required this.onTapParticipant,
    required this.topInset,
    required this.bottomInset,
  });

  final List<lk.Participant> participants;
  final bool isVideo;
  final String? focusSid;
  final bool autoFocused;
  final Map<String, List<SfuCallReaction>> reactionsByIdentity;
  final Set<String> raisedHands;
  final ValueChanged<SfuCallReaction> onReactionCompleted;
  final ValueChanged<String> onTapParticipant;
  final double topInset;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    if (participants.isEmpty) return const SizedBox.shrink();
    final main = participants.first;
    final rest = participants.skip(1).toList(growable: false);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, topInset, 12, bottomInset),
      child: Column(
        children: [
          Expanded(
            child: _SfuTile(
              participant: main,
              isVideo: isVideo,
              focused: main.sid == focusSid,
              autoFocused: autoFocused && main.sid == focusSid,
              reactions: reactionsByIdentity[main.identity] ?? const [],
              raisedHand: raisedHands.contains(main.identity),
              onReactionCompleted: onReactionCompleted,
              onTap: () => onTapParticipant(main.sid),
            ),
          ),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 112,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: rest.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, index) {
                  final participant = rest[index];
                  return SizedBox(
                    width: 132,
                    child: _SfuTile(
                      participant: participant,
                      isVideo: isVideo,
                      compact: true,
                      focused: participant.sid == focusSid,
                      autoFocused: autoFocused && participant.sid == focusSid,
                      reactions:
                          reactionsByIdentity[participant.identity] ?? const [],
                      raisedHand: raisedHands.contains(participant.identity),
                      onReactionCompleted: onReactionCompleted,
                      onTap: () => onTapParticipant(participant.sid),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SfuTile extends StatelessWidget {
  const _SfuTile({
    required this.participant,
    required this.isVideo,
    required this.focused,
    required this.autoFocused,
    required this.reactions,
    required this.raisedHand,
    required this.onReactionCompleted,
    required this.onTap,
    this.compact = false,
  });

  final lk.Participant participant;
  final bool isVideo;
  final bool focused;
  final bool autoFocused;
  final List<SfuCallReaction> reactions;
  final bool raisedHand;
  final ValueChanged<SfuCallReaction> onReactionCompleted;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final pubs = participant.videoTrackPublications;
    final pub = pubs.isNotEmpty ? pubs.first : null;
    final track = pub?.track;
    final videoMuted = pub?.muted ?? true;
    final speaking = participant.isSpeaking;
    final name = participant.name.isNotEmpty
        ? participant.name
        : participant.identity;

    Widget content;
    if (isVideo && track is lk.VideoTrack && !videoMuted) {
      content = lk.VideoTrackRenderer(track);
    } else {
      content = Center(
        child: GlowAvatar(username: name, size: compact ? 54 : 96),
      );
    }

    final radius = BorderRadius.circular(compact ? 16 : 20);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF070D1A)),
            content,
            if (raisedHand)
              const Positioned(top: 8, left: 8, child: RaiseHandBadge()),
            if (focused)
              Positioned(
                top: 8,
                right: 8,
                child: _FocusBadge(autoFocused: autoFocused),
              ),
            if (participant.connectionQuality != lk.ConnectionQuality.unknown)
              Positioned(
                top: focused ? 42 : 8,
                right: 8,
                child: ConnectionQualityBars(
                  key: Key('sfu-quality-${participant.identity}'),
                  quality: participant.connectionQuality,
                ),
              ),
            for (final reaction in reactions)
              Align(
                alignment: Alignment.center,
                child: FloatingReaction(
                  key: ValueKey(reaction.id),
                  emoji: reaction.emoji,
                  onCompleted: () => onReactionCompleted(reaction),
                ),
              ),
            Positioned(
              left: compact ? 7 : 10,
              right: compact ? 7 : 10,
              bottom: compact ? 7 : 10,
              child: CallParticipantLabel(
                name: name,
                muted: !participant.isMicrophoneEnabled(),
                compact: compact,
              ),
            ),
            // Hairline ring, or a green ring while the participant is speaking.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: speaking || focused
                          ? callAnswerColor.withValues(alpha: 0.85)
                          : Colors.white.withValues(alpha: 0.14),
                      width: speaking || focused ? 2.5 : 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FocusBadge extends StatelessWidget {
  const _FocusBadge({required this.autoFocused});

  final bool autoFocused;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      useOwnLayer: true,
      quality: GlassQuality.standard,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      settings: LiquidGlassSettings(
        glassColor: callAnswerColor.withValues(alpha: 0.34),
      ),
      child: Icon(
        autoFocused
            ? Icons.center_focus_strong_rounded
            : Icons.push_pin_rounded,
        color: Colors.white,
        size: 17,
      ),
    );
  }
}
