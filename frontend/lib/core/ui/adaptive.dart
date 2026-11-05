import 'dart:ui' show ImageFilter;

import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:material_ui/material_ui.dart' as m;

import '../platform/platform_kind.dart';
import '../theme/every_theme.dart';
import 'anchored_popover.dart';
import 'every_icons.dart';

/// Design-language-aware building blocks. Screens compose these instead of
/// importing a design system directly, so one screen definition renders
/// natively as Cupertino, macOS, Material 3, Fluent or Adwaita.
///
/// Each design system lives behind an import prefix:
/// `c` (cupertino_ui), `mac` (macos_ui), `m` (material_ui), `f` (fluent_ui).

DesignLanguage designOf(BuildContext context) => EveryTheme.of(context).design;

class AdaptiveIcon extends StatelessWidget {
  const AdaptiveIcon(this.icon, {super.key, this.size, this.color});

  final EveryIcon icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Icon(icon.of(designOf(context)), size: size, color: color);
}

class AdaptiveIconButton extends StatelessWidget {
  const AdaptiveIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.size,
  });

  final EveryIcon icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final design = designOf(context);
    final glyph = Icon(icon.of(design), size: size, color: color);
    return switch (design) {
      DesignLanguage.cupertino => Semantics(
        label: tooltip,
        button: true,
        child: c.CupertinoButton(
          padding: const EdgeInsets.all(8),
          minimumSize: const Size.square(40),
          onPressed: onPressed,
          child: glyph,
        ),
      ),
      DesignLanguage.macos => mac.MacosTooltip(
        message: tooltip,
        child: mac.MacosIconButton(
          icon: Icon(
            icon.of(design),
            size: size ?? 18,
            color: color ?? mac.MacosTheme.of(context).typography.body.color,
          ),
          semanticLabel: tooltip,
          boxConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: const EdgeInsets.all(5),
          onPressed: onPressed,
        ),
      ),
      DesignLanguage.fluent => f.Tooltip(
        message: tooltip,
        child: f.IconButton(
          icon: Icon(icon.of(design), size: size ?? 16, color: color),
          onPressed: onPressed,
        ),
      ),
      DesignLanguage.material ||
      DesignLanguage.adwaita => onMaterial(context, m.IconButton(tooltip: tooltip, icon: glyph, onPressed: onPressed)),
    };
  }
}

enum ButtonEmphasis { primary, secondary, plain, destructive }

class AdaptiveButton extends StatelessWidget {
  const AdaptiveButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.emphasis = ButtonEmphasis.primary,
    this.icon,
    this.expand = false,
    this.busy = false,
    bool? large,
  }) : large = large ?? expand;

  final String label;
  final VoidCallback? onPressed;
  final ButtonEmphasis emphasis;
  final Widget? icon;
  final bool expand;

  /// The native large size, for forms and full-width actions. Buttons inside
  /// content (cards, rows) are compact. Defaults to [expand].
  final bool large;

  /// Shows a spinner in place of the label and disables the button.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final onPressed = busy ? null : this.onPressed;
    final content = busy
        ? SizedBox.square(dimension: large ? 18 : 14, child: const AdaptiveProgress())
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[icon!, const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  // Compact buttons share one label size across design languages.
                  style: large ? null : theme.type.callout.medium,
                ),
              ),
            ],
          );
    final destructive = emphasis == ButtonEmphasis.destructive;
    final cupertinoSize = large ? c.CupertinoButtonSize.large : c.CupertinoButtonSize.small;
    final materialSize = large
        ? null
        : m.ButtonStyle(
            visualDensity: m.VisualDensity.compact,
            minimumSize: const m.WidgetStatePropertyAll(Size(0, 34)),
            padding: const m.WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
            textStyle: m.WidgetStatePropertyAll(theme.type.callout.medium),
          );

    final Widget button = switch (theme.design) {
      DesignLanguage.cupertino => switch (emphasis) {
        // Filled buttons are brand violet 500 with white text.
        ButtonEmphasis.primary => c.CupertinoButton.filled(
          sizeStyle: cupertinoSize,
          color: theme.primary,
          onPressed: onPressed,
          child: content,
        ),
        ButtonEmphasis.secondary => c.CupertinoButton.tinted(
          sizeStyle: cupertinoSize,
          onPressed: onPressed,
          child: content,
        ),
        _ => c.CupertinoButton(
          sizeStyle: cupertinoSize,
          onPressed: onPressed,
          child: DefaultTextStyle.merge(
            style: TextStyle(color: destructive ? theme.danger : null),
            child: content,
          ),
        ),
      },
      DesignLanguage.macos => mac.PushButton(
        controlSize: large ? mac.ControlSize.large : mac.ControlSize.regular,
        secondary: emphasis != ButtonEmphasis.primary,
        color: destructive
            ? theme.danger
            : emphasis == ButtonEmphasis.primary
            ? theme.primary
            : null,
        onPressed: onPressed,
        child: content,
      ),
      DesignLanguage.fluent => switch (emphasis) {
        ButtonEmphasis.primary => f.FilledButton(onPressed: onPressed, child: content),
        ButtonEmphasis.plain => f.HyperlinkButton(onPressed: onPressed, child: content),
        _ => f.Button(
          onPressed: onPressed,
          child: DefaultTextStyle.merge(
            style: TextStyle(color: destructive ? theme.danger : null),
            child: content,
          ),
        ),
      },
      DesignLanguage.material || DesignLanguage.adwaita => onMaterial(context, switch (emphasis) {
        ButtonEmphasis.primary => m.FilledButton(style: materialSize, onPressed: onPressed, child: content),
        ButtonEmphasis.secondary => m.FilledButton.tonal(style: materialSize, onPressed: onPressed, child: content),
        ButtonEmphasis.plain => m.TextButton(style: materialSize, onPressed: onPressed, child: content),
        ButtonEmphasis.destructive => m.TextButton(
          style: m.TextButton.styleFrom(foregroundColor: theme.danger).merge(materialSize),
          onPressed: onPressed,
          child: content,
        ),
      }),
    };
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class AdaptiveTextField extends StatelessWidget {
  const AdaptiveTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.obscureText = false,
    this.autofillHints,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.minLines,
    this.maxLines = 1,
    this.prefix,
    this.autofocus = false,
    this.borderless = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final bool obscureText;
  final Iterable<String>? autofillHints;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final int? minLines;
  final int? maxLines;
  final Widget? prefix;
  final bool autofocus;

  /// For fields embedded in a custom container (the composer).
  final bool borderless;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return switch (theme.design) {
      DesignLanguage.cupertino => c.CupertinoTextField(
        controller: controller,
        focusNode: focusNode,
        placeholder: placeholder,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        minLines: minLines,
        maxLines: maxLines,
        autofocus: autofocus,
        prefix: prefix == null ? null : Padding(padding: const EdgeInsets.only(left: 8), child: prefix),
        padding: borderless ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        placeholderStyle: theme.type.body.tint(theme.textMuted),
        decoration: borderless
            ? null
            : BoxDecoration(color: theme.surfaceRaised, borderRadius: BorderRadius.circular(theme.radius)),
        style: theme.type.body.tint(theme.text),
      ),
      DesignLanguage.macos => mac.MacosTextField(
        controller: controller,
        focusNode: focusNode,
        placeholder: placeholder,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        minLines: minLines,
        maxLines: maxLines,
        autofocus: autofocus,
        prefix: prefix,
        padding: borderless ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        style: (borderless ? theme.type.body : theme.type.callout).tint(theme.text),
        placeholderStyle: (borderless ? theme.type.body : theme.type.callout).tint(
          theme.textMuted.withValues(alpha: 0.8),
        ),
        // macos_ui paints a 3px focus ring onto any non-null focusedDecoration.
        decoration: borderless ? null : mac.kDefaultRoundedBorderDecoration,
        focusedDecoration: borderless ? null : mac.kDefaultFocusedBorderDecoration,
      ),
      DesignLanguage.fluent => f.TextBox(
        controller: controller,
        focusNode: focusNode,
        placeholder: placeholder,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        minLines: minLines,
        maxLines: maxLines,
        autofocus: autofocus,
        prefix: prefix == null ? null : Padding(padding: const EdgeInsets.only(left: 8), child: prefix),
        decoration: borderless ? const f.WidgetStatePropertyAll(BoxDecoration()) : null,
        highlightColor: borderless ? const Color(0x00000000) : null,
        unfocusedColor: borderless ? const Color(0x00000000) : null,
      ),
      DesignLanguage.material || DesignLanguage.adwaita => onMaterial(
        context,
        m.TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscureText,
          autofillHints: autofillHints,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          minLines: minLines,
          maxLines: maxLines,
          autofocus: autofocus,
          decoration: borderless
              ? m.InputDecoration.collapsed(hintText: placeholder)
              : m.InputDecoration(
                  hintText: placeholder,
                  prefixIcon: prefix,
                  filled: true,
                  isDense: true,
                  border: m.OutlineInputBorder(
                    borderRadius: BorderRadius.circular(theme.radius),
                    borderSide: theme.design == DesignLanguage.adwaita
                        ? BorderSide(color: theme.border)
                        : BorderSide.none,
                  ),
                ),
        ),
      ),
    };
  }
}

class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => switch (designOf(context)) {
    DesignLanguage.cupertino => c.CupertinoSwitch(value: value, onChanged: onChanged),
    DesignLanguage.macos => mac.MacosSwitch(value: value, onChanged: onChanged),
    DesignLanguage.fluent => f.ToggleSwitch(checked: value, onChanged: onChanged),
    DesignLanguage.material ||
    DesignLanguage.adwaita => onMaterial(context, m.Switch(value: value, onChanged: onChanged)),
  };
}

class AdaptiveProgress extends StatelessWidget {
  const AdaptiveProgress({super.key, this.value});

  final double? value;

  @override
  Widget build(BuildContext context) => switch (designOf(context)) {
    DesignLanguage.cupertino => const c.CupertinoActivityIndicator(),
    DesignLanguage.macos => mac.ProgressCircle(value: value),
    DesignLanguage.fluent => f.ProgressRing(value: value == null ? null : value! * 100, strokeWidth: 2.5),
    DesignLanguage.material || DesignLanguage.adwaita => m.CircularProgressIndicator(value: value, strokeWidth: 2.5),
  };
}

/// A row in a list: conversations, settings, models.
class AdaptiveListTile extends StatelessWidget {
  const AdaptiveListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.dense = false,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    // A wide trailing widget (a value, a picker) never takes the title's room, in any design: at most 55% of the row.
    return LayoutBuilder(builder: (context, box) => _tile(context, box.maxWidth));
  }

  Widget? _cappedTrailing(double width) => trailing == null
      ? null
      : ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width.isFinite ? width * 0.55 : double.infinity),
          child: trailing,
        );

  Widget _tile(BuildContext context, double width) {
    final theme = EveryTheme.of(context);
    final trailing = _cappedTrailing(width);
    switch (theme.design) {
      case DesignLanguage.fluent:
        return f.ListTile.selectable(
          leading: leading,
          title: title,
          subtitle: subtitle,
          trailing: trailing,
          selected: selected,
          onPressed: onTap,
        );
      case DesignLanguage.material || DesignLanguage.adwaita:
        return onMaterial(
          context,
          m.ListTile(
            leading: leading,
            title: title,
            subtitle: subtitle,
            trailing: trailing,
            selected: selected,
            dense: dense,
            onTap: onTap,
            shape: m.RoundedRectangleBorder(borderRadius: BorderRadius.circular(theme.radius)),
          ),
        );
      case DesignLanguage.cupertino || DesignLanguage.macos:
        // Apple lists: a rounded highlight for the selection, and secondary text in the label color.
        final highlight = selected ? theme.accent.withValues(alpha: theme.isDark ? 0.22 : 0.14) : null;
        return _PressableRow(
          onTap: onTap,
          highlight: highlight,
          radius: theme.radius,
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: dense ? 6 : 10),
          child: Builder(
            builder: (context) => Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 10)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DefaultTextStyle.merge(
                        style: (theme.design == DesignLanguage.macos ? theme.type.callout : theme.type.body).tint(
                          theme.text,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: title,
                      ),
                      if (subtitle != null)
                        DefaultTextStyle.merge(
                          style: (theme.design == DesignLanguage.macos ? theme.type.footnote : theme.type.caption).tint(
                            theme.textMuted,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          child: subtitle!,
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing],
              ],
            ),
          ),
        );
    }
  }
}

class _PressableRow extends StatefulWidget {
  const _PressableRow({
    required this.child,
    required this.onTap,
    required this.highlight,
    required this.radius,
    required this.padding,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? highlight;
  final double radius;
  final EdgeInsets padding;

  @override
  State<_PressableRow> createState() => _PressableRowState();
}

class _PressableRowState extends State<_PressableRow> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final overlay = _down
        ? theme.text.withValues(alpha: 0.10)
        : _hover
        ? theme.text.withValues(alpha: 0.05)
        : null;
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: Semantics(
          button: widget.onTap != null,
          selected: widget.highlight != null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: widget.padding,
            decoration: BoxDecoration(
              color: Color.alphaBlend(overlay ?? const Color(0x00000000), widget.highlight ?? const Color(0x00000000)),
              borderRadius: BorderRadius.circular(widget.radius),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Section header for grouped lists ("Today", "Appearance").
class AdaptiveSectionHeader extends StatelessWidget {
  const AdaptiveSectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final upper = theme.design == DesignLanguage.cupertino;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
      child: Text(
        upper ? label.toUpperCase() : label,
        style: (theme.design == DesignLanguage.macos ? theme.type.footnote : theme.type.caption).semibold.copyWith(
          color: theme.textMuted,
          letterSpacing: upper ? 0.4 : 0.1,
        ),
      ),
    );
  }
}

/// A menu item for [AdaptiveMenuButton].
@immutable
class MenuAction {
  const MenuAction({
    required this.label,
    required this.onSelected,
    this.icon,
    this.checked = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onSelected;
  final EveryIcon? icon;
  final bool checked;
  final bool destructive;
}

/// A button that opens a menu. Every menu in the app is the same anchored
/// glass popover with [PopoverRow]s (the model picker, the composer's menus,
/// "…" menus, value pickers), on every platform, so they all look alike.
class AdaptiveMenuButton extends StatelessWidget {
  const AdaptiveMenuButton({super.key, required this.actions, required this.child, this.tooltip, this.width});

  final List<MenuAction> actions;
  final Widget child;
  final String? tooltip;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final popover = AnchoredPopover(
      width: width,
      builder: (context, close) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final a in actions)
              PopoverRow(
                title: a.label,
                destructive: a.destructive,
                selected: a.checked,
                leading: a.icon == null
                    ? null
                    : AdaptiveIcon(a.icon!, size: 16, color: a.destructive ? theme.danger : theme.textMuted),
                trailing: a.checked ? Icon(EveryIcon.check.of(theme.design), size: 14, color: theme.accent) : null,
                onTap: () {
                  close();
                  a.onSelected();
                },
              ),
          ],
        ),
      ),
      child: child,
    );
    return tooltip == null ? popover : Semantics(label: tooltip, button: true, child: popover);
  }
}

/// The trigger for a value picker: the current value in accent text with an
/// up/down chevron, like a native pop-up button. Pair it with
/// [AdaptiveMenuButton] or [AnchoredPopover].
class MenuTrigger extends StatelessWidget {
  const MenuTrigger(this.label, {super.key, this.leading, this.muted = false});

  final String label;
  final Widget? leading;

  /// Secondary text color instead of the accent (triggers inside dense chrome).
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = muted ? theme.textMuted : theme.accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.callout.medium.tint(color),
            ),
          ),
          const SizedBox(width: 4),
          Icon(EveryIcon.chevronUpDown.of(theme.design), size: 13, color: color),
        ],
      ),
    );
  }
}

/// Native confirmation dialog. Resolves to true when the user confirms.
/// `detail` is shown in full below the message, in a scrolling box (for text
/// the user is asked to approve, which must never be cut short).
Future<bool> showAdaptiveConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  String? detail,
}) async {
  final theme = EveryTheme.of(context);
  Widget content({TextAlign align = TextAlign.start}) => detail == null
      ? Text(message, textAlign: align)
      : Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message, textAlign: align),
            const SizedBox(height: 10),
            ConfirmDetail(detail),
          ],
        );
  final Future<bool?> result = switch (theme.design) {
    DesignLanguage.cupertino => c.showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => c.CupertinoAlertDialog(
        title: Text(title),
        content: content(),
        actions: [
          c.CupertinoDialogAction(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          c.CupertinoDialogAction(
            isDestructiveAction: destructive,
            isDefaultAction: !destructive,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
    DesignLanguage.macos => mac.showMacosAlertDialog<bool>(
      context: context,
      builder: (ctx) => mac.MacosAlertDialog(
        appIcon: AdaptiveIcon(destructive ? EveryIcon.delete : EveryIcon.spark, size: 40, color: theme.accent),
        title: Text(title),
        message: content(align: TextAlign.center),
        primaryButton: mac.PushButton(
          controlSize: mac.ControlSize.large,
          color: destructive ? theme.danger : null,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
        secondaryButton: mac.PushButton(
          controlSize: mac.ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
      ),
    ),
    DesignLanguage.fluent => f.showDialog<bool>(
      context: context,
      builder: (ctx) => f.ContentDialog(
        title: Text(title),
        content: content(),
        actions: [
          f.FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(confirmLabel)),
          f.Button(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        ],
      ),
    ),
    DesignLanguage.material || DesignLanguage.adwaita => m.showDialog<bool>(
      context: context,
      builder: (ctx) => m.AlertDialog(
        title: Text(title),
        content: content(),
        actions: [
          m.TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          m.FilledButton(
            style: destructive ? m.FilledButton.styleFrom(backgroundColor: theme.danger) : null,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  };
  return await result ?? false;
}

/// The full text a confirmation asks about, in a scrolling box.
class ConfirmDetail extends StatelessWidget {
  const ConfirmDetail(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.codeBackground,
          border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Text(text, textAlign: TextAlign.start, style: theme.type.callout.tint(theme.text)),
        ),
      ),
    );
  }
}

/// Single-field text prompt (rename and similar; [obscureText] for secrets).
/// Returns null when cancelled.
Future<String?> showAdaptivePrompt(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initialValue = '',
  bool obscureText = false,
  String? placeholder,
}) async {
  final theme = EveryTheme.of(context);
  // The field owns its controller, so it outlives the dialog's closing animation.
  var text = initialValue;
  Widget field(BuildContext ctx) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: _PromptField(
      initialValue: initialValue,
      obscureText: obscureText,
      placeholder: placeholder,
      onChanged: (v) => text = v,
      onSubmitted: (value) => Navigator.of(ctx).pop(value),
    ),
  );
  void cancel(BuildContext ctx) => Navigator.of(ctx).pop();
  void confirm(BuildContext ctx) => Navigator.of(ctx).pop(text);

  final Future<String?> result = switch (theme.design) {
    DesignLanguage.cupertino => c.showCupertinoDialog<String>(
      context: context,
      builder: (ctx) => c.CupertinoAlertDialog(
        title: Text(title),
        content: field(ctx),
        actions: [
          c.CupertinoDialogAction(onPressed: () => cancel(ctx), child: const Text('Cancel')),
          c.CupertinoDialogAction(isDefaultAction: true, onPressed: () => confirm(ctx), child: Text(confirmLabel)),
        ],
      ),
    ),
    DesignLanguage.macos => mac.showMacosAlertDialog<String>(
      context: context,
      builder: (ctx) => mac.MacosAlertDialog(
        appIcon: AdaptiveIcon(EveryIcon.edit, size: 40, color: theme.accent),
        title: Text(title),
        message: field(ctx),
        primaryButton: mac.PushButton(
          controlSize: mac.ControlSize.large,
          onPressed: () => confirm(ctx),
          child: Text(confirmLabel),
        ),
        secondaryButton: mac.PushButton(
          controlSize: mac.ControlSize.large,
          secondary: true,
          onPressed: () => cancel(ctx),
          child: const Text('Cancel'),
        ),
      ),
    ),
    DesignLanguage.fluent => f.showDialog<String>(
      context: context,
      builder: (ctx) => f.ContentDialog(
        title: Text(title),
        content: field(ctx),
        actions: [
          f.FilledButton(onPressed: () => confirm(ctx), child: Text(confirmLabel)),
          f.Button(onPressed: () => cancel(ctx), child: const Text('Cancel')),
        ],
      ),
    ),
    DesignLanguage.material || DesignLanguage.adwaita => m.showDialog<String>(
      context: context,
      builder: (ctx) => m.AlertDialog(
        title: Text(title),
        content: field(ctx),
        actions: [
          m.TextButton(onPressed: () => cancel(ctx), child: const Text('Cancel')),
          m.FilledButton(onPressed: () => confirm(ctx), child: Text(confirmLabel)),
        ],
      ),
    ),
  };
  return result;
}

class _PromptField extends StatefulWidget {
  const _PromptField({
    required this.initialValue,
    required this.obscureText,
    required this.placeholder,
    required this.onChanged,
    required this.onSubmitted,
  });

  final String initialValue;
  final bool obscureText;
  final String? placeholder;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  State<_PromptField> createState() => _PromptFieldState();
}

class _PromptFieldState extends State<_PromptField> {
  late final _controller = TextEditingController(text: widget.initialValue)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initialValue.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AdaptiveTextField(
    controller: _controller,
    autofocus: true,
    obscureText: widget.obscureText,
    placeholder: widget.placeholder,
    textInputAction: TextInputAction.done,
    onChanged: widget.onChanged,
    onSubmitted: widget.onSubmitted,
  );
}

/// Transient message: toast-style on desktop, snack bar on Material pages.
void showAdaptiveToast(BuildContext context, String message) {
  final theme = EveryTheme.of(context);
  // A snack bar needs a Scaffold under the caller; dialogs (Settings) have
  // none, so they get the overlay toast, which shows above them.
  if ((theme.design == DesignLanguage.material || theme.design == DesignLanguage.adwaita) &&
      m.Scaffold.maybeOf(context) != null) {
    m.ScaffoldMessenger.maybeOf(context)?.showSnackBar(m.SnackBar(content: Text(message)));
    return;
  }
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 0,
      right: 0,
      bottom: 32 + MediaQuery.paddingOf(context).bottom,
      child: IgnorePointer(
        child: Center(
          // The overlay may sit above the app's theme scope.
          child: EveryThemeScope(
            theme: theme,
            child: GlassSurface(
              level: GlassLevel.thick,
              radius: 999,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(message, style: theme.type.body.tint(theme.text)),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future<void>.delayed(const Duration(seconds: 2), entry.remove);
}

/// The brand kit's glass levels.
enum GlassLevel {
  /// Composer, chips, toolbars.
  thin(blur: 20, saturate: 1.4),

  /// Sidebar and rail.
  regular(blur: 30, saturate: 1.6),

  /// Popovers, menus, sheets.
  thick(blur: 44, saturate: 1.8);

  const GlassLevel({required this.blur, required this.saturate});
  final double blur;
  final double saturate;

  /// Tint over the blurred backdrop (the kit specifies dark; light mirrors it).
  Color tint(EveryTheme theme) => switch (this) {
    thin => theme.isDark ? const Color(0x0FFFFFFF) : const Color(0xB3FFFFFF),
    regular => theme.isDark ? EveryPalette.ink900.withValues(alpha: 0.55) : const Color(0xB3FAFAFE),
    thick => theme.isDark ? EveryPalette.ink850.withValues(alpha: 0.78) : const Color(0xE6FFFFFF),
  };

  Color border(EveryTheme theme) => theme.isDark
      ? switch (this) {
          thin => const Color(0x29FFFFFF),
          regular => const Color(0x1AFFFFFF),
          thick => const Color(0x1FFFFFFF),
        }
      : theme.border;

  /// The 1px specular line along the top edge.
  Color highlight(EveryTheme theme) => theme.isDark
      ? switch (this) {
          thin => const Color(0x47FFFFFF),
          regular => const Color(0x24FFFFFF),
          thick => const Color(0x2EFFFFFF),
        }
      : const Color(0xCCFFFFFF);
}

/// Translucent material behind floating chrome (composer, popovers, toasts),
/// following the brand kit's glass recipes: backdrop blur and saturation, a
/// tint, a hairline border and a top highlight. Works on every renderer.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child, this.radius, this.padding, this.level = GlassLevel.thin});

  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final GlassLevel level;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final r = BorderRadius.circular(radius ?? theme.radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.compose(
          outer: ColorFilter.matrix(_saturation(level.saturate)),
          inner: ImageFilter.blur(sigmaX: level.blur / 2, sigmaY: level.blur / 2),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: r,
            // Solid surfaces under the tint keep text legible over busy backdrops.
            color: Color.alphaBlend(level.tint(theme), theme.surface.withValues(alpha: theme.isDark ? 0.5 : 0.0)),
            border: Border.all(color: level.border(theme), width: 0.8),
          ),
          position: DecorationPosition.background,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.04, 0.04],
                colors: [level.highlight(theme), level.highlight(theme).withValues(alpha: 0), const Color(0x00FFFFFF)],
              ),
            ),
            child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
          ),
        ),
      ),
    );
  }

  static List<double> _saturation(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final i = 1 - s;
    return [
      i * r + s, i * g, i * b, 0, 0, //
      i * r, i * g + s, i * b, 0, 0,
      i * r, i * g, i * b + s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }
}

/// [child] (a Material widget: ListTile, TextField, InkWell) on a transparent Material when nothing above gives it
/// one, so it works in any parent instead of throwing "No Material widget found".
Widget onMaterial(BuildContext context, Widget child) =>
    m.Material.maybeOf(context) != null ? child : m.Material(type: m.MaterialType.transparency, child: child);
