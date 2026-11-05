import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/code_session.dart';
import 'domain/transcript.dart' show AlertSeverity, SecurityAlert;

/// What deserves an OS notification when a session goes from [from] to [to]:
/// it started waiting for the user, or it finished what it was doing.
/// Null for every other change (and for a first sighting, [from] null).
({String title, String body})? notificationFor(SessionStatus? from, SessionStatus to, String session) {
  if (from == null || from == to) return null;
  if (to == SessionStatus.needsInput) return (title: 'Needs your input', body: session);
  if (to == SessionStatus.done && (from == SessionStatus.running || from == SessionStatus.starting)) {
    return (title: 'Finished', body: session);
  }
  if (to == SessionStatus.failed && from == SessionStatus.running) return (title: 'Stopped on an error', body: session);
  return null;
}

/// Shows a notification outside the app.
abstract interface class SystemNotifier {
  Future<void> show(String title, String body);
}

/// Native commands (`osascript` on macOS, `notify-send` on Linux); other
/// platforms show nothing.
final class CommandNotifier implements SystemNotifier {
  const CommandNotifier();

  @override
  Future<void> show(String title, String body) async {
    try {
      if (Platform.isMacOS) {
        String q(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
        await Process.run('osascript', [
          '-e',
          'display notification ${q(body)} with title ${q('EveryAI')} subtitle ${q(title)}',
        ]);
      } else if (Platform.isLinux) {
        await Process.run('notify-send', ['--app-name=EveryAI', title, body]);
      }
    } on Object {
      // No notification service; the status dot still shows it.
    }
  }
}

final systemNotifierProvider = Provider<SystemNotifier>((ref) => const CommandNotifier());

/// Asks whether the app is in front, at the moment of asking (a cached
/// answer would hold for the life of the app); tests replace it.
final appFocusedProvider = Provider<bool Function()>((ref) => _appInFront);

bool _appInFront() {
  try {
    return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    // No binding (a headless test): there is no window to be behind.
    // ignore: avoid_catching_errors
  } on Error {
    return true;
  }
}

/// Notifies about a status change of [session] unless the app is in front
/// (then the status pill and the session list already show it).
void notifyStatusChange(Ref ref, SessionStatus? from, SessionStatus to, String session) {
  final n = notificationFor(from, to, session);
  if (n == null || ref.read(appFocusedProvider)()) return;
  unawaited(ref.read(systemNotifierProvider).show(n.title, n.body));
}

/// The notification for a security alert the agent of [session] raised.
({String title, String body}) securityNotification(SecurityAlert alert, String session) => (
  title: switch (alert.severity) {
    AlertSeverity.critical => 'Security alert: act now',
    AlertSeverity.warning => 'Security alert',
    AlertSeverity.info => 'Security note',
  },
  body: '$session: ${alert.what}${alert.stopRun ? ' The run stopped and waits for you.' : ''}',
);

/// Notifies about [alert], from any session (a subagent's or fork's too:
/// its transcript is off screen). A critical one goes out even with the app
/// in front; the others only when it is behind, like status changes.
void notifySecurityAlert(Ref ref, SecurityAlert alert, String session) {
  if (alert.severity != AlertSeverity.critical && ref.read(appFocusedProvider)()) return;
  final n = securityNotification(alert, session);
  unawaited(ref.read(systemNotifierProvider).show(n.title, n.body));
}

/// How long a session has to keep waiting before "Needs your input" goes out.
/// An approval the mode answers by itself (Auto-edit, Full auto) passes
/// through needsInput for a moment on every step; those blips aren't news.
const needsInputSettle = Duration(seconds: 3);

/// One session's notifications, with waits that end within [needsInputSettle]
/// left out. Feed it every status change; dispose it with the session.
final class StatusAlerts {
  StatusAlerts(this._ref, this._title, {Timer Function(Duration, void Function())? timer})
    : _startTimer = timer ?? Timer.new;

  final Ref _ref;
  final String Function() _title;
  final Timer Function(Duration, void Function()) _startTimer;

  Timer? _wait;

  /// The status before the current wait, so a blip doesn't count as the
  /// "from" of the next change (running → blip → done is still "Finished").
  SessionStatus? _beforeWait;

  void onChange(SessionStatus? from, SessionStatus to) {
    if (from == to) return;
    if (to == SessionStatus.needsInput) {
      // A first sighting (reopened while waiting) isn't news either.
      if (from == null) return;
      _wait?.cancel();
      _beforeWait = from;
      _wait = _startTimer(needsInputSettle, () {
        _wait = null;
        notifyStatusChange(_ref, _beforeWait, SessionStatus.needsInput, _title());
      });
      return;
    }
    var since = from;
    if (from == SessionStatus.needsInput && _wait != null) {
      // The wait ended before anyone was told: as if it never happened.
      _wait!.cancel();
      _wait = null;
      since = _beforeWait;
    }
    notifyStatusChange(_ref, since, to, _title());
  }

  void dispose() {
    _wait?.cancel();
    _wait = null;
  }
}
