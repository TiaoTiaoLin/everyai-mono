import 'session_processes.dart' show ProcessTable;

Future<List<int>> killSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> roots = const {},
}) async => const [];

Future<(ProcessTable, List<int>)?> findSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> roots = const {},
}) async => null;
