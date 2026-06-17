import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_config.dart';
import '../../widgets/glass.dart';

/// Shared iOS-26 Liquid Glass building blocks for the call screens — used by
/// both the P2P [CallScreen] and the LiveKit SFU screen so the two stay visually
/// identical. Pure surfaces (no BackdropFilter), safe to sit over a video
/// texture; control glass uses the shader-backed liquid_glass widgets.

const callEndColor = Color(0xFFFF453A);
const callAnswerColor = Color(0xFF30D158);

/// Dark radial-gradient call background with an optional faint avatar wash and a
/// top blue glow. A plain surface, safe behind an RTCVideoView / LiveKit texture.
class CallBackground extends StatelessWidget {
  final String? avatarUrl;
  final String username;

  const CallBackground({super.key, this.avatarUrl, required this.username});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.3),
                radius: 1.4,
                colors: [
                  Color(0xFF1A2340),
                  Color(0xFF070D1A),
                  Color(0xFF000000),
                ],
              ),
            ),
          ),
        ),
        if (avatarUrl != null)
          Positioned.fill(
            child: Opacity(
              opacity: 0.14,
              child: CachedNetworkImage(
                imageUrl: ApiConfig.resolveMedia(avatarUrl!),
                fit: BoxFit.cover,
              ),
            ),
          ),
        Positioned(
          top: -100,
          left: -100,
          right: -100,
          height: 500,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 1.0,
                colors: [
                  const Color(0xFF3D5AFE).withValues(alpha: 0.18),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Circular avatar with a soft blue glow; falls back to the initial.
class GlowAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String username;
  final double size;

  const GlowAvatar({
    super.key,
    this.avatarUrl,
    required this.username,
    this.size = 120,
  });

  @override
  Widget build(BuildContext context) {
    final initial = username.isNotEmpty
        ? username.substring(0, 1).toUpperCase()
        : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3D5AFE).withValues(alpha: 0.40),
            blurRadius: 48,
            spreadRadius: -4,
          ),
        ],
      ),
      child: ClipOval(
        child: avatarUrl != null
            ? CachedNetworkImage(
                imageUrl: ApiConfig.resolveMedia(avatarUrl!),
                fit: BoxFit.cover,
              )
            : Container(
                color: const Color(0xFF1A2340),
                child: Center(
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: size * 0.4,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// [GlowAvatar] wrapped in two expanding "sonar" rings — the FaceTime ringing /
/// connecting affordance. Plain widget (no glass), safe over [CallBackground].
/// Shared by the incoming-call modal and the SFU connecting state.
class PulsingGlowAvatar extends StatefulWidget {
  final String? avatarUrl;
  final String username;
  final double size;

  const PulsingGlowAvatar({
    super.key,
    this.avatarUrl,
    required this.username,
    this.size = 128,
  });

  @override
  State<PulsingGlowAvatar> createState() => _PulsingGlowAvatarState();
}

class _PulsingGlowAvatarState extends State<PulsingGlowAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _ring(double phase) {
    final scale = 1.0 + 0.46 * phase;
    final opacity = ((1.0 - phase) * 0.4).clamp(0.0, 1.0);
    return Container(
      width: widget.size * scale,
      height: widget.size * scale,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: opacity),
          width: 1.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size * 1.7,
      height: widget.size * 1.7,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final t = _pulse.value;
          return Stack(
            alignment: Alignment.center,
            children: [_ring(t), _ring((t + 0.5) % 1.0), child!],
          );
        },
        child: GlowAvatar(
          avatarUrl: widget.avatarUrl,
          username: widget.username,
          size: widget.size,
        ),
      ),
    );
  }
}

/// A single glass call control: icon button + label below. Tooltip is omitted on
/// purpose — it creates an Overlay layer that corrupts the video texture on
/// desktop compositors.
class CallControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color activeColor;
  final double size;

  const CallControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor = Colors.white,
    this.size = 56.0,
  });

  @override
  Widget build(BuildContext context) {
    final settings = active && activeColor != Colors.white
        ? LiquidGlassSettings(glassColor: activeColor.withValues(alpha: 0.45))
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassIconButton(
          icon: Icon(icon),
          onPressed: onTap,
          size: size,
          // Grouped into CallControlsPanel's single shared glass layer instead
          // of capturing its own backdrop per button (was double-glass).
          useOwnLayer: false,
          quality: GlassQuality.standard,
          glowColor: active ? activeColor : null,
          glowRadius: 18,
          settings: settings,
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: TextStyle(
            color: active
                ? (activeColor == Colors.white
                      ? Colors.white
                      : activeColor.withValues(alpha: 0.90))
                : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// iOS-26 controls panel: secondary actions in a glass pill above a full-width
/// End/Leave glass button.
class CallControlsPanel extends StatelessWidget {
  final List<Widget> secondaryControls;
  final VoidCallback onHangup;
  final double buttonSize;
  final bool desktopLayout;
  final bool compactLayout;
  final String endLabel;

  const CallControlsPanel({
    super.key,
    required this.secondaryControls,
    required this.onHangup,
    required this.buttonSize,
    required this.desktopLayout,
    required this.compactLayout,
    this.endLabel = 'End Call',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (secondaryControls.isNotEmpty) ...[
          GlassContainer(
            shape: const LiquidRoundedSuperellipse(borderRadius: 36),
            useOwnLayer: true,
            quality: GlassQuality.standard,
            padding: EdgeInsets.symmetric(
              horizontal: desktopLayout ? 20 : 8,
              vertical: desktopLayout ? 18 : 16,
            ),
            // One shared blend-group layer for the secondary buttons (the
            // documented grouped-toolbar idiom) so they capture the backdrop
            // once instead of per-button.
            child: AdaptiveLiquidGlassLayer(
              child: Wrap(
                alignment: WrapAlignment.center,
                runAlignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: desktopLayout ? 24 : (compactLayout ? 8 : 12),
                runSpacing: 14,
                children: secondaryControls,
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        LayoutBuilder(
          builder: (ctx, c) => GlassButton.custom(
            key: const Key('call-control-end'),
            onTap: onHangup,
            useOwnLayer: true,
            quality: GlassQuality.standard,
            width: c.maxWidth,
            height: desktopLayout ? 56 : 62,
            shape: const LiquidRoundedSuperellipse(borderRadius: 32),
            settings: LiquidGlassSettings(
              glassColor: callEndColor.withValues(alpha: 0.62),
            ),
            glowColor: callEndColor,
            glowRadius: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.call_end_rounded,
                  color: Colors.white,
                  size: 24,
                ),
                const SizedBox(width: 10),
                Text(
                  endLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class FloatingReaction extends StatefulWidget {
  final String emoji;
  final VoidCallback? onCompleted;

  const FloatingReaction({super.key, required this.emoji, this.onCompleted});

  @override
  State<FloatingReaction> createState() => _FloatingReactionState();
}

class _FloatingReactionState extends State<FloatingReaction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 2500),
        )
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) widget.onCompleted?.call();
        })
        ..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        return Opacity(
          opacity: (1 - t).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, -84 * t),
            child: Transform.scale(scale: 0.82 + 0.36 * (1 - t), child: child),
          ),
        );
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 0.7,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Text(widget.emoji, style: const TextStyle(fontSize: 34)),
        ),
      ),
    );
  }
}

class RaiseHandBadge extends StatelessWidget {
  const RaiseHandBadge({super.key});

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
      child: const Icon(Icons.back_hand_rounded, color: Colors.white, size: 17),
    );
  }
}

/// Pill name label (with optional mic-off badge) shown over a participant tile.
class CallParticipantLabel extends StatelessWidget {
  final String name;
  final bool muted;
  final bool compact;

  const CallParticipantLabel({
    super.key,
    required this.name,
    required this.muted,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.54),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.16),
            width: 0.6,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 5 : 7,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (muted) ...[
                Icon(
                  Icons.mic_off_rounded,
                  color: Colors.white70,
                  size: compact ? 12 : 14,
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  name,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
