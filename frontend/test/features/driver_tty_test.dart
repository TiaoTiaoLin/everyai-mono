@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:every_ai/features/code/drivers/driver_process_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plain pipes stand in for the pty (flutter_pty's library isn't loaded
/// under `flutter test`); what is tested is the JSON on the named pipes.
Future<TtyProgram> _piped(String executable, List<String> args, String cwd, Map<String, String> env) async {
  final p = await Process.start(
    executable,
    args,
    workingDirectory: cwd,
    environment: env,
    includeParentEnvironment: false,
  );
  return (pid: p.pid, exitCode: p.exitCode, output: p.stdout);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('driver-tty'));
  tearDown(() => tmp.delete(recursive: true));

  test('JSON lines go over the named pipes both ways; closing removes them', () async {
    final agent = File('${tmp.path}/agent.sh')
      ..writeAsStringSync(r'''
echo "to the log" >&2
while IFS= read -r line; do printf '%s\n' "$line"; done
''');
    final p = await spawnDriverTty(
      executable: '/bin/sh',
      args: [agent.path],
      cwd: tmp.path,
      sessionTag: 'tty-test',
      logPath: '${tmp.path}/s/stderr.log',
      start: _piped,
    );
    final first = p.lines.first;
    p.send('{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    expect(await first, '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    expect(p.lastError, contains('to the log'));
    await p.close();
    expect(File('${tmp.path}/s/acp.in').existsSync(), isFalse);
    expect(File('${tmp.path}/s/acp.out').existsSync(), isFalse);
  });

  test('a program that exits before opening the pipes still ends its lines', () async {
    final p = await spawnDriverTty(
      executable: '/nonexistent/grok',
      args: const [],
      cwd: tmp.path,
      sessionTag: 'tty-test-2',
      logPath: '${tmp.path}/s/stderr.log',
      start: (exe, args, cwd, env) => _piped('/bin/sh', ['-c', 'exit 3'], cwd, env),
    );
    expect(await p.lines.toList(), isEmpty);
    expect(await p.exitCode, 3);
    await p.close();
  });
}
