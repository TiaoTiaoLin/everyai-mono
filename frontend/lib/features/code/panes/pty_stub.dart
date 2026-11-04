import 'pty.dart';

bool get shellSupported => false;

ShellPty? startShell({
  required String workingDir,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) => null;

Future<ShellPty?> startProgram({
  required String executable,
  required List<String> args,
  required String workingDir,
  required String sessionTag,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) async => null;
