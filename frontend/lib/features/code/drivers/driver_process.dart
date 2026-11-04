// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'driver.dart';
import 'driver_process_stub.dart' if (dart.library.io) 'driver_process_io.dart' as impl;
import 'json_rpc.dart';

/// A coding CLI the app runs for a session: stdout as lines (JSON-RPC or
/// ndjson), stdin as lines, stderr appended to the session's log.
abstract interface class DriverProcess implements LineChannel {
  int get pid;
  Future<int> get exitCode;
}

/// Starts [executable] (an absolute path, see [detectCli]) in [cwd], the
/// session's worktree, with the login shell's environment plus [env] and
/// `EVERYAI_SESSION` = [sessionTag], so Stop and the Processes pane own what
/// it runs. stderr goes to [logPath]. Closing it ends its whole process tree.
Future<DriverProcess> spawnDriver({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
}) =>
    impl.spawnDriver(executable: executable, args: args, cwd: cwd, sessionTag: sessionTag, logPath: logPath, env: env);

final _closers = <Future<void> Function()>{};

/// Registers [close] to run when the app quits (processes that don't come from [spawnDriver], e.g. a pty).
void trackDriverClose(Future<void> Function() close) => _closers.add(close);
void untrackDriverClose(Future<void> Function() close) => _closers.remove(close);

/// Ends every driver process still running (the app is quitting).
Future<void> closeAllDriverProcesses() =>
    Future.wait([impl.closeAllDriverProcesses(), for (final c in _closers.toList()) c()]);

/// Looks for [command] on the login shell's PATH plus the usual install
/// directories (an app started from the Dock doesn't have the user's; no
/// process runs for the lookup) and asks it for its version: installed,
/// path and the first line of `[command] [versionArgs]`, which is ended
/// after 4 s. Whether it is signed in is the driver's own check. [which]
/// replaces the lookup (tests).
Future<DriverStatus> detectCli(
  String command, {
  List<String> versionArgs = const ['--version'],
  Future<String?> Function(String command)? which,
}) => impl.detectCli(command, versionArgs: versionArgs, which: which);

/// Reads the login shell's PATH again, for the next [detectCli] and spawn
/// (the user installed something since the app started).
Future<void> reloadShellEnv() => impl.reloadShellEnv();

/// The problem a driver whose sessions aren't built yet reports.
const notBuiltProblem = 'Not built yet.';

/// The problem a driver whose check ran out of time reports.
const noAnswerProblem = "Didn't answer in 8 s.";

/// [detectCli] for a driver whose sessions aren't built yet.
Future<DriverStatus> notBuiltYet(String command, {Future<String?> Function(String command)? which}) async =>
    (await detectCli(command, which: which)).withProblem(notBuiltProblem);
