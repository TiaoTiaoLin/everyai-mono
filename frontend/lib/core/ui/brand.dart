import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'layout.dart';

import 'package:flutter_svg/flutter_svg.dart';

import '../theme/every_theme.dart';

part 'brand_glyphs.dart';

/// The EveryAI mark (rounded E with the cyan dot), for the current theme.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    EveryTheme.of(context).isDark
        ? 'assets/brand/logo/mark-primary-on-dark.svg'
        : 'assets/brand/logo/mark-primary-on-light.svg',
    width: size,
    height: size,
    semanticsLabel: 'EveryAI',
  );
}

/// The round EveryAI avatar: the "EveryAI · Auto" router and system notes.
class BrandAvatar extends StatelessWidget {
  const BrandAvatar({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset('assets/brand/logo/everyai-avatar.svg', width: size, height: size, semanticsLabel: 'EveryAI');
}

/// What the agent is doing, shown by animating the mark.
enum MarkActivity {
  /// The arms fade in turn (top, middle, bottom).
  thinking,

  /// The dot pulses.
  streaming,

  /// The dot slides in from the middle arm.
  tool,
}

/// The mark as an activity indicator (brand kit motion spec). Static when
/// the platform asks for reduced motion.
class EveryMarkActivity extends StatefulWidget {
  const EveryMarkActivity({super.key, this.activity = MarkActivity.thinking, this.size = 18});

  final MarkActivity activity;
  final double size;

  @override
  State<EveryMarkActivity> createState() => _EveryMarkActivityState();
}

class _EveryMarkActivityState extends State<EveryMarkActivity> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _duration(widget.activity));

  static Duration _duration(MarkActivity a) => Duration(
    milliseconds: switch (a) {
      MarkActivity.thinking => 1200,
      MarkActivity.streaming => 900,
      MarkActivity.tool => 1400,
    },
  );

  @override
  void didUpdateWidget(EveryMarkActivity old) {
    super.didUpdateWidget(old);
    if (old.activity != widget.activity) {
      _c.duration = _duration(widget.activity);
      if (_c.isAnimating) _c.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: switch (widget.activity) {
        MarkActivity.thinking => 'Thinking',
        MarkActivity.streaming => 'Writing',
        MarkActivity.tool => 'Working',
      },
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _MarkPainter(
            progress: _c,
            activity: still ? null : widget.activity,
            body: theme.isDark ? EveryPalette.violet400 : EveryPalette.violet500,
            dot: theme.isDark ? EveryPalette.cyan400 : EveryPalette.cyan600,
          ),
        ),
      ),
    );
  }
}

/// Paints the mark from its parts (`in-app/motion/mark-parts.svg`, a 76-unit
/// box starting at 12,12).
class _MarkPainter extends CustomPainter {
  _MarkPainter({required this.progress, required this.activity, required this.body, required this.dot})
    : super(repaint: progress);

  final Animation<double> progress;
  final MarkActivity? activity;
  final Color body;
  final Color dot;

  static const _spine = Rect.fromLTWH(12, 12, 22, 76);
  static const _arms = [Rect.fromLTWH(12, 12, 76, 18), Rect.fromLTWH(12, 41, 49, 18), Rect.fromLTWH(12, 70, 76, 18)];

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    canvas
      ..save()
      ..scale(size.width / 76, size.height / 76)
      ..translate(-12, -12);
    final paint = Paint()..isAntiAlias = true;

    // Thinking: each arm fades 35% → 100% → 35%, 150 ms apart.
    double armAlpha(int i) {
      if (activity != MarkActivity.thinking) return 1;
      final phase = (t - i * 150 / 1200) % 1.0;
      final wave = Curves.easeInOut.transform(phase < 0.5 ? phase * 2 : (1 - phase) * 2);
      return 0.35 + 0.65 * wave;
    }

    canvas.drawRRect(RRect.fromRectAndRadius(_spine, const Radius.circular(9)), paint..color = body);
    for (final (i, arm) in _arms.indexed) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(arm, const Radius.circular(9)),
        paint..color = body.withValues(alpha: armAlpha(i)),
      );
    }
    // The spine covers the arms' left ends at full strength.
    if (activity == MarkActivity.thinking) {
      canvas.drawRRect(RRect.fromRectAndRadius(_spine, const Radius.circular(9)), paint..color = body);
    }

    var center = const Offset(79, 50);
    var radius = 9.0;
    var alpha = 1.0;
    switch (activity) {
      case MarkActivity.streaming:
        final wave = Curves.easeInOut.transform(t < 0.5 ? t * 2 : (1 - t) * 2);
        radius = 9 * (1 - 0.45 * wave);
      case MarkActivity.tool:
        final e = const Cubic(0.2, 0.8, 0.2, 1).transform(math.min(t / 0.7, 1));
        center = Offset(79 - 38 * (1 - e), 50);
        alpha = e;
      case MarkActivity.thinking || null:
        break;
    }
    canvas.drawCircle(center, radius, paint..color = dot.withValues(alpha: alpha));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.activity != activity || old.body != body || old.dot != dot;
}

/// A feature glyph (chat, search, research, code, artifacts, connectors,
/// projects, models, compare, images, voice, extended-thinking). The dot
/// carries state: grey at rest, cyan (dark) or violet (light) when [active].
class BrandGlyph extends StatelessWidget {
  const BrandGlyph(this.name, {super.key, this.active = false, this.size = 20, this.color});

  final String name;
  final bool active;
  final double size;

  /// Stroke color; defaults to the kit's rest/active stroke.
  final Color? color;

  static bool has(String name) => _glyphs.containsKey(name);

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final (d, cx, cy) = _glyphs[name]!;
    final stroke =
        color ?? (theme.isDark ? (active ? const Color(0xFFFFFFFF) : EveryPalette.ink200) : EveryPalette.ink900);
    final dot = active ? theme.signal : EveryPalette.ink400;
    final strokeOpacity = stroke.a;
    final svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
        '<path d="$d" fill="none" stroke="${_hex(stroke)}" stroke-opacity="$strokeOpacity" stroke-width="1.75" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
        '<circle cx="$cx" cy="$cy" r="1.5" fill="${_hex(dot)}"/></svg>';
    return SvgPicture.string(svg, width: size, height: size, excludeFromSemantics: true);
  }
}

/// An empty state: the kit's illustration, a title and a line of help.
class BrandEmptyState extends StatelessWidget {
  const BrandEmptyState({super.key, required this.kind, required this.title, this.message, this.action});

  /// `empty-chats`, `no-results` or `offline`.
  final String kind;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final light = !theme.isDark && kind != 'empty-chats';
    // Centered when it fits, scrolling on a short window, plain inside a list.
    return CenteredScroll(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset('assets/brand/empty/$kind${light ? '-light' : ''}.svg', width: 72, height: 72),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: theme.type.headline.tint(theme.text)),
          if (message != null) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.type.body.copyWith(color: theme.textMuted, height: 1.4),
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

/// The Horizon field (dark) or Daybreak (light), for sign-in and splash-like
/// surfaces. Never behind chat text.
class BrandField extends StatelessWidget {
  const BrandField({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final shape = size.width > size.height ? 'desktop-2880x1800' : 'phone-1290x2796';
    final field = theme.isDark ? 'horizon' : 'daybreak';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.isDark ? EveryPalette.ink1000 : EveryPalette.ink50,
        image: DecorationImage(image: AssetImage('assets/brand/fields/$field-$shape.webp'), fit: BoxFit.cover),
      ),
      child: child,
    );
  }
}
