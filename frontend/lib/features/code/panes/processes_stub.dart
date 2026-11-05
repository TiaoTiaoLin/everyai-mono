import '../domain/local_ports.dart';
import 'processes.dart';

Future<List<SessionProcess>> listSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> agentRoots = const {},
  Set<int> terminalShells = const {},
}) async => const [];

Future<List<ListeningPort>> listeningPorts(Iterable<int> pids) async => const [];

bool killProcess(int pid, {bool force = false}) => false;
