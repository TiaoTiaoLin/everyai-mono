import 'package:every_ai/features/code/harness/session_processes.dart';
import 'package:flutter_test/flutter_test.dart';

ProcessRow _row(int pid, int ppid, String cmd, {String? tag, bool env = true}) =>
    ProcessRow(pid: pid, ppid: ppid, command: cmd, tag: tag, envVisible: env);

void main() {
  const dir = '/w/session-a';
  // 10 tmux server → shells 20 (session a), 30 (session b).
  final table = ProcessTable([
    _row(10, 1, 'tmux -L everyai new-session'),
    _row(20, 10, '/bin/bash', env: false),
    _row(21, 20, 'python gen.py', tag: 'a'),
    _row(22, 21, '/bin/sleep 600', env: false),
    _row(23, 20, 'node server.js', tag: 'a'),
    _row(30, 10, '/bin/bash', env: false),
    _row(31, 30, 'python other.py', tag: 'b'),
    _row(40, 1, 'node orphan.js', tag: 'a'),
    _row(41, 1, '/bin/sleep 900', env: false),
    _row(42, 1, '/Applications/Editor.app/Editor', tag: null),
  ]);

  test('finds the shells and orphans', () {
    expect(table.shells, unorderedEquals([20, 30]));
    expect(table.orphans, unorderedEquals([40, 41, 42]));
  });

  test("takes everything under the session's shell, never the shell or the tmux server", () {
    final pids = table.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: false);
    expect(pids, [21, 22, 23, 40]);
  });

  test("leaves other sessions' processes alone", () {
    expect(table.sessionProcesses(tag: 'b', workingDir: '/w/session-b', ownsDir: true), [31]);
  });

  test("a driver CLI's tools are the session's, the CLI itself is spared", () {
    // The app (5) started the CLI (50); its tools carry no visible tag.
    final t = ProcessTable([
      _row(5, 1, '/Applications/EveryAI.app/EveryAI'),
      _row(50, 5, '/usr/local/bin/claude', tag: 'a'),
      _row(51, 50, '/bin/bash -c npm test', env: false),
      _row(52, 51, 'node jest', env: false),
      _row(60, 5, '/usr/local/bin/codex', tag: 'b'),
      _row(61, 60, 'cargo build', env: false),
    ]);
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: true, roots: {50}), [51, 52]);
    // Without a root its tools can't be told apart.
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: true), isEmpty);
    // A root that has exited is skipped.
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: true, roots: {99}), isEmpty);
  });

  test('driver roots are kept per session until unregistered', () {
    registerDriverRoot('t1', 50);
    registerDriverRoot('t1', 51);
    registerDriverRoot('t2', 60);
    expect(driverRootsOf('t1'), {50, 51});
    unregisterDriverRoot('t1', 50);
    unregisterDriverRoot('t1', 51);
    unregisterDriverRoot('t2', 60);
    expect(driverRootsOf('t1'), isEmpty);
    expect(driverRootsOf('t2'), isEmpty);
  });

  test('untagged orphans count by working directory', () {
    final t = ProcessTable([_row(41, 1, '/bin/sleep 900', env: false), _row(43, 1, '/bin/sleep 900', env: false)]);
    final cwds = {41: dir, 43: '/w/session-b'};
    expect(t.needsCwd(), unorderedEquals([41, 43]));
    // An orphan counts only when the session has the directory to itself.
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: false, cwds: cwds), isEmpty);
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: true, cwds: cwds), [41]);
    // A sibling directory with the same prefix is not inside.
    expect(t.sessionProcesses(tag: 'a', workingDir: '/w/session', ownsDir: true, cwds: cwds), isEmpty);
  });

  test("the user's own tmux is never taken for the agent's", () {
    final t = ProcessTable([
      // The user's tmux, with a pane in the same folder running an editor and a dev server.
      _row(70, 1, 'tmux'),
      _row(71, 70, '/bin/zsh', env: false),
      _row(72, 71, 'nvim .'),
      _row(73, 71, 'npm run dev'),
    ]);
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: true, cwds: {71: dir}), isEmpty);
  });

  test('parses ps output with and without the environment', () {
    const plain = '''
  101     1 /bin/sleep 600
  102     1 python gen.py --n 5
  103   102 node a.js
''';
    const withEnv = '''
  101     1 /bin/sleep 600
  102     1 python gen.py --n 5 HOME=/u EVERYAI_SESSION=abc-1 PATH=/bin
  103   102 node a.js HOME=/u
''';
    final t = ProcessTable.parsePs(withEnv, plain);
    expect(t.rows[101]!.envVisible, isFalse);
    expect(t.rows[102]!.tag, 'abc-1');
    expect(t.rows[102]!.command, 'python gen.py --n 5');
    expect(t.rows[103]!.tag, isNull);
    expect(t.rows[103]!.envVisible, isTrue);
    expect(t.rows[103]!.ppid, 102);
  });

  test('reads the tag from /proc environ', () {
    expect(ProcessTable.tagInEnviron('A=1\x00EVERYAI_SESSION=xyz\x00B=2'), 'xyz');
    expect(ProcessTable.tagInEnviron('A=1\x00B=2'), isNull);
  });
}
