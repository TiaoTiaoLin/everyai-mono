import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:macos_window_utils/widgets/transparent_macos_sidebar.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../core/platform/platform_kind.dart';
import '../core/preferences.dart';
import '../core/theme/every_theme.dart';
import '../core/ui/adaptive.dart' show showAdaptiveToast;
import '../features/code/code_providers.dart' show driverShutdownProvider;
import '../features/history/ui/sidebar.dart';
import '../features/remote/remote_providers.dart' show remoteHostingProvider;
import '../features/settings/byok_keys.dart' show modelBillingProvider;
import '../features/settings/settings_registry.dart';
import '../features/settings/ui/settings_modal.dart';
import 'router.dart';

/// Lets pages toggle the sidebar and know whether it is showing.
class ShellScope extends InheritedWidget {
  const ShellScope({
    super.key,
    required this.sidebarVisible,
    required this.compact,
    required this.toggleSidebar,
    required super.child,
  });

  final bool sidebarVisible;
  final bool compact;
  final VoidCallback toggleSidebar;

  /// Pages show a sidebar button only when the sidebar is an overlay drawer;
  /// on wide windows it collapses to a rail that is always present.
  bool get showSidebarButton => compact;

  static ShellScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>()!;

  @override
  bool updateShouldNotify(ShellScope old) => sidebarVisible != old.sidebarVisible || compact != old.compact;
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _collapsedKey = 'sidebar.collapsed';

  late bool _collapsed = ref.read(preferencesProvider)[_collapsedKey] == 'true'; // wide layouts
  bool _drawerOpen = false; // compact layouts

  void _toggle(bool compact) => setState(() {
    if (compact) {
      _drawerOpen = !_drawerOpen;
    } else {
      _collapsed = !_collapsed;
      ref.read(preferencesProvider)[_collapsedKey] = '$_collapsed';
    }
  });

  void _navigate(String location) {
    setState(() => _drawerOpen = false);
    context.go(location);
  }

  @override
  void initState() {
    super.initState();
    // A settings link that came before the shell existed (the first location).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(pendingSettingsProvider) != null) _openPendingSettings();
    });
  }

  void _openSettings() {
    setState(() => _drawerOpen = false);
    showSettings(context);
  }

  void _openPendingSettings() {
    final t = ref.read(pendingSettingsProvider.notifier).take();
    if (t == null || !mounted) return;
    setState(() => _drawerOpen = false);
    showSettings(context, section: t.section, anchor: t.anchor, args: t.args);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final compact = WindowSize.of(context) == WindowSize.compact;
    // Loads the user's keys and billing picks for the request paths outside
    // Riverpod (the Code harness reads ModelBilling.current).
    ref.listen(modelBillingProvider, (_, _) {});
    // Hosting for remote devices runs app-wide (when the user turned it on);
    // a device asking to pair is announced wherever the user is.
    if (Host.isDesktop) {
      // Outside coding CLIs end with the app, whichever way they were started.
      ref.listen(driverShutdownProvider, (_, _) {});
      ref.listen(remoteHostingProvider.select((s) => s.link.pending.length), (before, now) {
        if (now > (before ?? 0)) {
          showAdaptiveToast(context, 'A device wants to use Code here. Approve it in Settings → Remote.');
        }
      });
    }
    // Old /settings links ask for the Settings modal; it opens over the page.
    ref.listen(pendingSettingsProvider, (_, next) {
      if (next != null) _openPendingSettings();
    });

    Widget body = _SplitView(
      compact: compact,
      collapsed: _collapsed,
      drawerOpen: _drawerOpen,
      onDismissDrawer: () => setState(() => _drawerOpen = false),
      sidebar: _SidebarSurface(
        child: Sidebar(
          location: widget.location,
          collapsed: !compact && _collapsed,
          onNavigate: _navigate,
          onToggle: () => _toggle(compact),
        ),
      ),
      content: widget.child,
    );
    // macOS: MacosWindow supplies the window chrome; the sidebar draws its own
    // vibrancy so it can collapse to a rail (macos_ui's Sidebar only hides).
    if (theme.design == DesignLanguage.macos) body = mac.MacosWindow(child: body);

    body = ShellScope(
      sidebarVisible: compact ? _drawerOpen : true,
      compact: compact,
      toggleSidebar: () => _toggle(compact),
      child: body,
    );

    final apple = Host.isApple;
    SingleActivator shortcut(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(key, meta: apple, control: !apple, shift: shift);
    final shortcuts = <ShortcutActivator, VoidCallback>{
      shortcut(LogicalKeyboardKey.keyN): () => _navigate(Routes.newChat),
      shortcut(LogicalKeyboardKey.comma): _openSettings,
      shortcut(LogicalKeyboardKey.keyM, shift: true): () => _navigate(Routes.models),
      shortcut(LogicalKeyboardKey.keyS, shift: true): () => _toggle(compact),
    };
    body = CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(autofocus: true, child: body),
    );

    if (Host.isApple && defaultTargetPlatform == TargetPlatform.macOS) {
      body = PlatformMenuBar(
        menus: [
          PlatformMenu(
            label: 'EveryAI',
            menus: [
              const PlatformMenuItemGroup(
                members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about)],
              ),
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Settings…',
                    shortcut: shortcut(LogicalKeyboardKey.comma),
                    onSelected: _openSettings,
                  ),
                ],
              ),
              const PlatformMenuItemGroup(
                members: [
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
                ],
              ),
            ],
          ),
          PlatformMenu(
            label: 'File',
            menus: [
              PlatformMenuItem(
                label: 'New Chat',
                shortcut: shortcut(LogicalKeyboardKey.keyN),
                onSelected: () => _navigate(Routes.newChat),
              ),
            ],
          ),
          PlatformMenu(
            label: 'View',
            menus: [
              PlatformMenuItem(
                label: 'Toggle Sidebar',
                shortcut: shortcut(LogicalKeyboardKey.keyS, shift: true),
                onSelected: () => _toggle(compact),
              ),
              PlatformMenuItem(
                label: 'Models',
                shortcut: shortcut(LogicalKeyboardKey.keyM, shift: true),
                onSelected: () => _navigate(Routes.models),
              ),
              const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
            ],
          ),
          const PlatformMenu(
            label: 'Window',
            menus: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
            ],
          ),
        ],
        child: body,
      );
    }

    // Material widgets need a Material ancestor for ink and text styles.
    if (theme.design == DesignLanguage.material || theme.design == DesignLanguage.adwaita) {
      body = m.Material(color: theme.background, child: body);
    }
    return body;
  }
}

/// Sidebar + content. Wide: side by side; the sidebar collapses to an icon rail.
/// Compact: an overlay drawer with the full sidebar.
class _SplitView extends StatelessWidget {
  const _SplitView({
    required this.compact,
    required this.collapsed,
    required this.drawerOpen,
    required this.onDismissDrawer,
    required this.sidebar,
    required this.content,
  });

  final bool compact;
  final bool collapsed;
  final bool drawerOpen;
  final VoidCallback onDismissDrawer;
  final Widget sidebar;
  final Widget content;

  static const _width = 272.0;
  static const _duration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion ? Duration.zero : _duration;

    if (!compact) {
      return Row(
        children: [
          AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            width: collapsed ? sidebarRailWidth(theme.design) : _width,
            child: ClipRect(child: sidebar),
          ),
          Container(width: 1, color: theme.border),
          Expanded(child: content),
        ],
      );
    }

    final width = (MediaQuery.sizeOf(context).width * 0.85).clamp(0.0, 320.0);
    return Stack(
      children: [
        Positioned.fill(child: content),
        IgnorePointer(
          ignoring: !drawerOpen,
          child: GestureDetector(
            onTap: onDismissDrawer,
            child: AnimatedContainer(
              duration: duration,
              color: drawerOpen ? const Color(0x66000000) : const Color(0x00000000),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: duration,
          curve: Curves.easeOutCubic,
          top: 0,
          bottom: 0,
          left: drawerOpen ? 0 : -width - 8,
          width: width,
          child: GestureDetector(
            onHorizontalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -300) onDismissDrawer();
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                boxShadow: [if (drawerOpen) const BoxShadow(color: Color(0x40000000), blurRadius: 24)],
              ),
              child: sidebar,
            ),
          ),
        ),
      ],
    );
  }
}

/// Native sidebar material per design language.
class _SidebarSurface extends StatelessWidget {
  const _SidebarSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final content = SafeArea(right: false, child: child);
    return switch (theme.design) {
      // Native NSVisualEffectView vibrancy behind a cleared Flutter layer. The
      // native view only resizes when this widget builds, so rebuild on every
      // constraint change (rail ↔ expanded animation, window resize).
      DesignLanguage.macos when !kIsWeb => LayoutBuilder(
        builder: (context, constraints) => TransparentMacOSSidebar(
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Color(0xFF000000), backgroundBlendMode: BlendMode.clear),
            child: content,
          ),
        ),
      ),
      DesignLanguage.fluent => f.Mica(child: content),
      DesignLanguage.cupertino => ColoredBox(
        color: theme.isDark ? EveryPalette.ink900 : const Color(0xFFF2F2F7),
        child: content,
      ),
      DesignLanguage.adwaita => ColoredBox(
        color: theme.isDark ? EveryPalette.ink900 : const Color(0xFFEBEBED),
        child: content,
      ),
      _ => m.Material(color: theme.surface, child: content),
    };
  }
}
