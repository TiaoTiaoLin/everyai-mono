// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// A window on screen (macOS), front to back as CoreGraphics lists them.
typedef ScreenWindow = ({int id, int pid, String owner, String title, int width, int height});

/// Which window a screenshot takes, and whose it is.
sealed class WindowPick {
  const WindowPick();
}

/// A window of an app this session started; [others] more of the session's
/// windows match too.
final class OwnWindow extends WindowPick {
  const OwnWindow(this.window, this.others);
  final ScreenWindow window;
  final int others;
}

/// A window only `app` or `window_id` names: it belongs to another app, so
/// the user decides.
final class ForeignWindow extends WindowPick {
  const ForeignWindow(this.window);
  final ScreenWindow window;
}

final class NoWindow extends WindowPick {
  const NoWindow();
}

/// Picks from [all] (frontmost first): window [windowId] when given, else the
/// frontmost of the session's ([own]) windows that match [app] (owner or
/// title, any case), else the frontmost other window matching [app]. Windows
/// smaller than 40 px a side (status items, tooltips) never count.
WindowPick pickWindow(List<ScreenWindow> all, {required bool Function(ScreenWindow) own, String? app, int? windowId}) {
  final windows = [
    for (final w in all)
      if (w.width >= 40 && w.height >= 40) w,
  ];
  if (windowId != null) {
    final w = windows.where((w) => w.id == windowId).firstOrNull;
    if (w == null) return const NoWindow();
    return own(w) ? OwnWindow(w, 0) : ForeignWindow(w);
  }
  final q = app?.trim().toLowerCase() ?? '';
  final named = [
    for (final w in windows)
      if (q.isEmpty || w.owner.toLowerCase().contains(q) || w.title.toLowerCase().contains(q)) w,
  ];
  final mine = named.where(own).toList();
  if (mine.isNotEmpty) return OwnWindow(mine.first, mine.length - 1);
  if (q.isNotEmpty && named.isNotEmpty) return ForeignWindow(named.first);
  return const NoWindow();
}

/// How a screenshot names [w] ("Counter — Home (800x600)").
String windowLabel(ScreenWindow w) => '${w.owner}${w.title.isEmpty ? '' : ' — ${w.title}'} (${w.width}x${w.height})';

/// Which of [all] are a session's own: their process is one of [pids], or
/// it runs from inside [root] (an app built there and opened with `open`).
Future<bool Function(ScreenWindow w)> sessionOwner(
  List<ScreenWindow> all, {
  required Set<int> pids,
  required String root,
  required Future<String> Function(int pid) executableOf,
}) async {
  final exe = <int, String>{};
  for (final w in all) {
    if (w.width < 40 || w.height < 40 || pids.contains(w.pid) || exe.containsKey(w.pid)) continue;
    exe[w.pid] = await executableOf(w.pid);
  }
  return (ScreenWindow w) => pids.contains(w.pid) || (exe[w.pid] ?? '').startsWith('$root/');
}

/// [pickWindow] with [sessionOwner]'s windows as the session's own, and
/// those [granted] says the user allowed.
Future<WindowPick> pickSessionWindow(
  List<ScreenWindow> all, {
  required Set<int> pids,
  required String root,
  required Future<String> Function(int pid) executableOf,
  bool Function(ScreenWindow w)? granted,
  String? app,
  int? windowId,
}) async {
  final owner = await sessionOwner(all, pids: pids, root: root, executableOf: executableOf);
  return pickWindow(all, own: (w) => owner(w) || (granted?.call(w) ?? false), app: app, windowId: windowId);
}
