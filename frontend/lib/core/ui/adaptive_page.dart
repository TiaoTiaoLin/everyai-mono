import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:material_ui/material_ui.dart' as m;

import '../../app/shell.dart';
import '../platform/platform_kind.dart';
import '../theme/every_theme.dart';
import 'adaptive.dart';
import 'every_icons.dart';

/// The width macos_ui's ToolBar keeps free for the traffic lights when no
/// sidebar sits under them (our compact layout, where the sidebar is a drawer).
const _macTrafficLights = 70.0;

/// macos_ui ToolBar's horizontal padding plus the spacing NavigationToolbar
/// puts on each side of the middle slot.
const _macToolbarGutters = 8.0 * 2 + 8.0 * 2;

/// Gives the [AdaptivePage]s below a back control when they don't set their
/// own (Settings pages on narrow windows).
class PageBackScope extends InheritedWidget {
  const PageBackScope({super.key, required this.onBack, this.tooltip = 'Back', required super.child});

  final VoidCallback? onBack;
  final String tooltip;

  static PageBackScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PageBackScope>();

  @override
  bool updateShouldNotify(PageBackScope old) => onBack != old.onBack || tooltip != old.tooltip;
}

/// A top-level page with native chrome:
/// - Cupertino: translucent navigation bar that content scrolls beneath (glass)
/// - macOS: unified toolbar inside the window, sidebar toggle implied
/// - Fluent: page header with a command row, on Mica
/// - Material 3: top app bar; Adwaita: compact centered header bar
///
/// [body] starts below the bar on its own: no screen has to remember the bar's
/// height. A body whose scroll view consumes `MediaQuery.padding` (a ListView
/// does) may set [scrollsUnderBar] so its content slides under a translucent
/// bar; nothing else sees that padding.
class AdaptivePage extends StatelessWidget {
  const AdaptivePage({
    super.key,
    required this.title,
    this.titleWidget,
    this.actions = const [],
    this.onBack,
    this.backTooltip = 'Back',
    this.header,
    this.scrollsUnderBar = false,
    required Widget body,
  }) : _body = body; // ignore: prefer_initializing_formals

  final String title;

  /// Replaces the plain title (the chat screen's model picker).
  final Widget? titleWidget;
  final List<Widget> actions;

  /// Shows a back control before the title (settings pages opened from
  /// elsewhere, child sessions).
  final VoidCallback? onBack;
  final String backTooltip;

  /// Stays put below the bar while [body] scrolls (a search field, filters).
  /// The body then starts below it, not under the bar.
  final Widget? header;

  /// The body's own scroll view takes the bar's height as padding (a ListView
  /// with no padding of its own) and wants its content to slide under the bar.
  /// Off: the body starts below the bar.
  final bool scrollsUnderBar;
  final Widget _body;

  /// The page's content: [header] pinned below the bar, then the body. Under
  /// a translucent bar a header in a plain Column would sit beneath the bar.
  Widget get body {
    final top = header;
    if (top == null) {
      if (scrollsUnderBar) return _body;
      return Builder(
        builder: (context) {
          final inset = MediaQuery.paddingOf(context).top;
          if (inset == 0) return _body;
          return Padding(
            padding: EdgeInsets.only(top: inset),
            child: MediaQuery.removePadding(context: context, removeTop: true, child: _body),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            // On a short window the header never takes more than half the height; past that it scrolls itself.
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight.isFinite ? box.maxHeight / 2 : double.infinity),
              child: SingleChildScrollView(primary: false, child: top),
            ),
          ),
          Expanded(
            child: MediaQuery.removePadding(context: context, removeTop: true, child: _body),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final shell = ShellScope.of(context);
    final titleView = titleWidget ?? Text(title, overflow: TextOverflow.ellipsis, maxLines: 1);
    final sidebarButton = shell.showSidebarButton && theme.design != DesignLanguage.macos
        ? AdaptiveIconButton(icon: EveryIcon.menu, tooltip: 'Show sidebar', onPressed: shell.toggleSidebar)
        : null;
    final scope = PageBackScope.maybeOf(context);
    final back = onBack ?? scope?.onBack;
    final backButton = back == null
        ? null
        : AdaptiveIconButton(
            icon: EveryIcon.chevronLeft,
            tooltip: onBack != null ? backTooltip : scope!.tooltip,
            onPressed: back,
          );
    final leadingButtons = [?sidebarButton, ?backButton];
    final leading = leadingButtons.isEmpty
        ? null
        : leadingButtons.length == 1
        ? leadingButtons.single
        : Row(mainAxisSize: MainAxisSize.min, children: leadingButtons);

    switch (theme.design) {
      case DesignLanguage.cupertino:
        return c.CupertinoPageScaffold(
          backgroundColor: theme.background,
          navigationBar: c.CupertinoNavigationBar(
            leading: leading,
            middle: titleView,
            trailing: actions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: actions),
            backgroundColor: theme.surface.withValues(alpha: 0.55),
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: true,
            border: Border(bottom: BorderSide(color: theme.border, width: 0)),
          ),
          child: body,
        );
      case DesignLanguage.macos:
        // macos_ui's ToolBar gives the title a fixed width and moves actions
        // into an overflow menu wholesale. Instead the whole bar is one row
        // in the title slot, sized to the real width: the title takes what
        // the actions leave and ellipsizes first.
        return LayoutBuilder(
          builder: (context, constraints) {
            final lights = shell.compact ? _macTrafficLights : 0.0;
            final width = (constraints.maxWidth - lights - _macToolbarGutters).clamp(0.0, double.infinity);
            final window = mac.MacosWindowScope.maybeOf(context);
            final bar = mac.ToolBar(
              title: Row(
                children: [
                  ?backButton,
                  if (backButton != null) const SizedBox(width: 4),
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: titleView),
                  ),
                  for (final a in actions) ...[const SizedBox(width: 6), a],
                ],
              ),
              titleWidth: width,
              enableBlur: true,
            );
            final scaffold = mac.MacosScaffold(
              toolBar: bar,
              children: [mac.ContentArea(builder: (context, _) => body)],
            );
            if (window == null) return scaffold;
            // The ToolBar reserves the traffic-light inset unless it thinks a
            // sidebar is showing; ours is always under the lights on wide
            // windows.
            return mac.MacosWindowScope(
              constraints: window.constraints,
              isSidebarShown: !shell.compact,
              isEndSidebarShown: window.isEndSidebarShown,
              sidebarToggler: window.toggleSidebar,
              endSidebarToggler: window.toggleEndSidebar,
              child: scaffold,
            );
          },
        );
      case DesignLanguage.fluent:
        return f.ScaffoldPage(
          padding: EdgeInsets.zero,
          header: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: f.PageHeader(
              leading: leading == null ? null : Padding(padding: const EdgeInsets.only(right: 8), child: leading),
              title: DefaultTextStyle.merge(style: theme.type.title, child: titleView),
              commandBar: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
            ),
          ),
          content: body,
        );
      case DesignLanguage.material || DesignLanguage.adwaita:
        return m.Scaffold(
          backgroundColor: theme.background,
          appBar: m.AppBar(
            automaticallyImplyLeading: false,
            leading: leading,
            leadingWidth: leadingButtons.length > 1 ? 96 : null,
            title: titleView,
            actions: [...actions, const SizedBox(width: 8)],
          ),
          body: body,
        );
    }
  }
}

/// Puts [child] below a translucent bar when it sits in a body that scrolls under one ([AdaptivePage.scrollsUnderBar]):
/// a side panel next to such a list. Nothing changes where the body already starts below the bar.
class BelowBar extends StatelessWidget {
  const BelowBar({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    if (top == 0) return child;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
    );
  }
}
