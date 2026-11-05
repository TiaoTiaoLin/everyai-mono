import 'package:flutter/foundation.dart';

import '../domain/local_ports.dart';
import 'processes_stub.dart' if (dart.library.io) 'processes_io.dart' as impl;

/// Who started a process in the session.
enum ProcessOrigin { agent, terminal }

/// A process of a Code session, for the Processes pane.
@immutable
final class SessionProcess {
  const SessionProcess({
    required this.pid,
    required this.ppid,
    required this.command,
    required this.origin,
    this.ports = const [],
  });

  final int pid;
  final int ppid;
  final String command;
  final ProcessOrigin origin;
  final List<ListeningPort> ports;

  /// The program's name, without its folder or arguments.
  String get name {
    final first = command.trimLeft().split(RegExp(r'\s')).first;
    return first.substring(first.lastIndexOf('/') + 1);
  }
}

/// The processes the agent's terminal left running for session [tag] (see
/// `killSessionProcesses`), the trees of [agentRoots] (the app app_run
/// started), and everything below the user's own terminal shells
/// [terminalShells], with the ports they listen on. Empty where processes
/// can't be listed.
Future<List<SessionProcess>> listSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> agentRoots = const {},
  Set<int> terminalShells = const {},
}) => impl.listSessionProcesses(
  tag: tag,
  workingDir: workingDir,
  ownsDir: ownsDir,
  agentRoots: agentRoots,
  terminalShells: terminalShells,
);

/// The TCP ports [pids] listen on (none where that can't be found).
Future<List<ListeningPort>> listeningPorts(Iterable<int> pids) => impl.listeningPorts(pids);

/// Sends SIGTERM (or SIGKILL with [force]) to [pid].
bool killProcess(int pid, {bool force = false}) => impl.killProcess(pid, force: force);
