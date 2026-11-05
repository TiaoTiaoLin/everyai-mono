import 'package:flutter/widgets.dart';

import '../theme/every_theme.dart';
import 'adaptive.dart';
import 'every_icons.dart';

/// A row of pill buttons choosing one value, inline (no menu): usage ranges,
/// the theme, a settings scope. Give [icon] to show a glyph, alone when
/// [label] returns '' (the label then only names it for screen readers via
/// [semanticLabel]).
class AdaptiveSegmented<T> extends StatelessWidget {
  const AdaptiveSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.icon,
    this.semanticLabel,
    this.enabled,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;
  final EveryIcon Function(T)? icon;
  final String Function(T)? semanticLabel;

  /// Which values can be picked (all by default).
  final bool Function(T)? enabled;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: theme.border),
      ),
      // Segments share the width when it runs short; each label ellipsizes rather than overflowing.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final v in values) Flexible(child: _segment(theme, v))],
      ),
    );
  }

  Widget _segment(EveryTheme theme, T v) {
    final on = v == selected;
    final can = enabled?.call(v) ?? true;
    final color = !can
        ? theme.textMuted.withValues(alpha: 0.5)
        : on
        ? theme.text
        : theme.textMuted;
    final text = label(v);
    final glyph = icon?.call(v);
    return Semantics(
      button: true,
      selected: on,
      enabled: can,
      label: semanticLabel?.call(v) ?? (text.isEmpty ? null : text),
      child: GestureDetector(
        key: ValueKey('segment.$v'),
        behavior: HitTestBehavior.opaque,
        onTap: can ? () => onSelected(v) : null,
        child: MouseRegion(
          cursor: can ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: text.isEmpty ? 8 : 10, vertical: 5),
            decoration: BoxDecoration(
              color: on ? theme.accent.withValues(alpha: 0.16) : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (glyph != null) AdaptiveIcon(glyph, size: 14, color: color),
                if (glyph != null && text.isNotEmpty) const SizedBox(width: 5),
                if (text.isNotEmpty)
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (on ? theme.type.callout.semibold : theme.type.callout.medium).tint(color),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
