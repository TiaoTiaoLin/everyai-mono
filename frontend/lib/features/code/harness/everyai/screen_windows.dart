// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// A window on screen (macOS), front to back as CoreGraphics lists them.
typedef ScreenWindow = ({int id, int pid, String owner, String title, int width, int height});

/// Which window a screenshot takes, and whose it is.
sealed class WindowPick {
  const WindowPick();
}

/// A window of an app this session started; [others] more of the session's
/// windows match too. [skipped]: windows the query also named that are never
/// captured ([sensitiveWindow]).
final class OwnWindow extends WindowPick {
  const OwnWindow(this.window, this.others, {this.skipped = const []});
  final ScreenWindow window;
  final int others;
  final List<String> skipped;
}

/// A window only `app` or `window_id` names: it belongs to another app, so
/// the user decides.
final class ForeignWindow extends WindowPick {
  const ForeignWindow(this.window);
  final ScreenWindow window;
}

/// No window to take; [skipped] lists the ones the query named that are never
/// captured ("1Password (a password manager)").
final class NoWindow extends WindowPick {
  const NoWindow({this.skipped = const []});
  final List<String> skipped;
}

/// What the screenshot tools say about [skipped] windows, or ''.
String skippedText(List<String> skipped) => skipped.isEmpty
    ? ''
    : 'Skipped ${skipped.join(', ')}: EveryAI never captures password managers or banking and payment pages.';

/// Password managers and keychains, by the name macOS lists as the window's
/// owner. Their windows are never captured, whoever asks.
const _passwordManagers = {
  '1password',
  '1password 7',
  'bitwarden',
  'lastpass',
  'dashlane',
  'keepassxc',
  'keepassium',
  'strongbox',
  'enpass',
  'proton pass',
  'nordpass',
  'keychain access',
  'passwords',
};

/// The same apps by their bundle in the executable's path (owner names of
/// Apple's apps are localized).
final _passwordManagerBundle = RegExp(
  r'/(1Password( 7)?|Bitwarden|LastPass|Dashlane|KeePassXC|KeePassium|Strongbox|Enpass|Proton Pass|NordPass|'
  r'Keychain Access|Passwords)\.app/',
  caseSensitive: false,
);

const _browsers = {
  'safari',
  'google chrome',
  'arc',
  'firefox',
  'microsoft edge',
  'brave browser',
  'chromium',
  'opera',
  'vivaldi',
};

/// A best effort: titles leak (a checkout page need not say so), so this is
/// a short list, not a promise.
final _moneyTitle = RegExp(r'\b(bank|banking|checkout|payment|payments|paypal)\b', caseSensitive: false);

/// Why a screenshot never takes [w], or null: a password manager or keychain
/// (by owner name, or by [exe], its process's executable, when known), or,
/// for a browser window the session didn't start ([own] false), a title that
/// looks like a bank or a payment page.
String? sensitiveWindow(ScreenWindow w, {required bool own, String exe = ''}) {
  final owner = w.owner.trim().toLowerCase();
  if (_passwordManagers.contains(owner) ||
      (owner == 'system settings' && w.title.trim().toLowerCase() == 'passwords') ||
      _passwordManagerBundle.hasMatch(exe)) {
    return 'a password manager';
  }
  if (!own && _browsers.contains(owner) && _moneyTitle.hasMatch(w.title)) return 'looks like a banking or payment page';
  return null;
}

/// Picks from [all] (frontmost first): window [windowId] when given, else the
/// frontmost of the session's ([own]) windows that match [app] (owner or
/// title, any case), else the frontmost other window matching [app]. Windows
/// smaller than 40 px a side (status items, tooltips) never count, nor do
/// [sensitiveWindow]s ([exe] gives a window's executable when known), not even
/// granted ones: those the query named come back as `skipped`.
WindowPick pickWindow(
  List<ScreenWindow> all, {
  required bool Function(ScreenWindow) own,
  String? app,
  int? windowId,
  String Function(ScreenWindow w)? exe,
}) {
  final q = app?.trim().toLowerCase() ?? '';
  bool asked(ScreenWindow w) => windowId != null
      ? w.id == windowId
      : q.isNotEmpty && (w.owner.toLowerCase().contains(q) || w.title.toLowerCase().contains(q));
  final skipped = <String>[];
  final windows = <ScreenWindow>[];
  for (final w in all) {
    if (w.width < 40 || w.height < 40) continue;
    if (sensitiveWindow(w, own: own(w), exe: exe?.call(w) ?? '') case final why?) {
      if (asked(w)) skipped.add('${w.owner} ($why)');
      continue;
    }
    windows.add(w);
  }
  if (windowId != null) {
    final w = windows.where((w) => w.id == windowId).firstOrNull;
    if (w == null) return NoWindow(skipped: skipped);
    return own(w) ? OwnWindow(w, 0) : ForeignWindow(w);
  }
  final named = [
    for (final w in windows)
      if (q.isEmpty || w.owner.toLowerCase().contains(q) || w.title.toLowerCase().contains(q)) w,
  ];
  final mine = named.where(own).toList();
  if (mine.isNotEmpty) return OwnWindow(mine.first, mine.length - 1, skipped: skipped);
  if (q.isNotEmpty && named.isNotEmpty) return ForeignWindow(named.first);
  return NoWindow(skipped: skipped);
}

/// How a screenshot names [w] ("Counter — Home (800x600)").
String windowLabel(ScreenWindow w) => '${w.owner}${w.title.isEmpty ? '' : ' — ${w.title}'} (${w.width}x${w.height})';

/// The executable of each window's process in [all], except [pids].
Future<Map<int, String>> _executables(
  List<ScreenWindow> all, {
  required Set<int> pids,
  required Future<String> Function(int pid) executableOf,
}) async {
  final exe = <int, String>{};
  for (final w in all) {
    if (w.width < 40 || w.height < 40 || pids.contains(w.pid) || exe.containsKey(w.pid)) continue;
    exe[w.pid] = await executableOf(w.pid);
  }
  return exe;
}

/// [pickWindow] with a session's own windows as own (their process is one of
/// [pids], or it runs from inside [root]: an app built there and opened with
/// `open`), and those [granted] says the user allowed.
Future<WindowPick> pickSessionWindow(
  List<ScreenWindow> all, {
  required Set<int> pids,
  required String root,
  required Future<String> Function(int pid) executableOf,
  bool Function(ScreenWindow w)? granted,
  String? app,
  int? windowId,
}) async {
  final exe = await _executables(all, pids: pids, executableOf: executableOf);
  bool owner(ScreenWindow w) => pids.contains(w.pid) || (exe[w.pid] ?? '').startsWith('$root/');
  return pickWindow(
    all,
    own: (w) => owner(w) || (granted?.call(w) ?? false),
    app: app,
    windowId: windowId,
    exe: (w) => exe[w.pid] ?? '',
  );
}
