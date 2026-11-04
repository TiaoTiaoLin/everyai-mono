import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/terminal/terminal_driver.dart';
import 'package:every_ai/features/code/drivers/terminal/terminal_session.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/session_processes.dart';
import 'package:every_ai/features/code/panes/pty.dart';
import 'package:flutter_test/flutter_test.dart';

final class FakePty implements ShellPty {
  final _out = StreamController<Uint8List>();
  final _exit = Completer<int>();
  final writes = <List<int>>[];
  var kills = 0;

  @override
  int get pid => 4242;
  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void write(Uint8List data) => writes.add(data);
  @override
  void resize(int rows, int columns) {}
  @override
  void kill() => kills++;

  void emit(String s) => _out.add(Uint8List.fromList(utf8.encode(s)));
  void exit(int code) => _exit.complete(code);
  List<String> get texts => [for (final w in writes) utf8.decode(w)];
}

SessionSpec _spec({DriverBriefing? briefing}) => SessionSpec(
  workingDir: '/work',
  model: 'm',
  mode: AgentMode.ask,
  llmBaseUrl: 'http://127.0.0.1:9/v1',
  llmApiKey: 'k',
  sessionTag: 'tag-t',
  briefing: briefing,
);

TerminalDriver _driver(FakePty? pty, {List<Map<String, Object?>>? started, Future<String?> Function(String)? read}) =>
    TerminalDriver(
      id: 'terminal:aider',
      label: 'aider',
      command: 'aider',
      args: const ['--no-auto-commits'],
      which: (c) async => c == 'aider' ? '/bin/aider' : null,
      startPty: ({required executable, required args, required workingDir, required sessionTag}) async {
        started?.add({'exe': executable, 'args': args, 'cwd': workingDir, 'tag': sessionTag});
        return pty;
      },
      readText: read ?? (_) async => null,
    );

Future<(TerminalSession, FakePty)> _open({DriverBriefing? briefing, Future<String?> Function(String)? read}) async {
  final pty = FakePty();
  final s = await _driver(pty, read: read).start(_spec(briefing: briefing)) as TerminalSession;
  return (s, pty);
}

void main() {
  group('driver', () {
    test('detects through the lookup; no caps, models or statuses', () async {
      expect((await _driver(null).detect()).installed, isTrue);
      final missing = TerminalDriver(id: 'terminal:x', label: 'x', command: 'x', which: (_) async => null);
      expect((await missing.detect()).installed, isFalse);
      final d = _driver(null);
      expect(d.caps, isEmpty);
      expect(await d.models(), isEmpty);
      expect(await d.statuses(['a']), isEmpty);
      await expectLater(d.attach('c'), throwsA(isA<HarnessError>()));
    });

    test('start gives the pty its program, folder and tag, and registers the pid', () async {
      final started = <Map<String, Object?>>[];
      final pty = FakePty();
      final s = await _driver(pty, started: started).start(_spec());
      expect(started.single, {
        'exe': '/bin/aider',
        'args': ['--no-auto-commits'],
        'cwd': '/work',
        'tag': 'tag-t',
      });
      expect(driverRootsOf('tag-t'), {4242});
      await s.close();
      expect(driverRootsOf('tag-t'), isEmpty);
      expect(pty.kills, 1);
      await s.close();
      expect(pty.kills, 1);
    });

    test('no pty, or no program, is an error', () async {
      await expectLater(_driver(null).start(_spec()), throwsA(isA<HarnessError>()));
      final missing = TerminalDriver(id: 'terminal:x', label: 'x', command: 'x', which: (_) async => null);
      await expectLater(missing.start(_spec()), throwsA(isA<HarnessError>()));
    });

    test('the registry makes one for terminal:<command>', () {
      final d = DriverRegistry(const {}).resolve('terminal:aider');
      expect(d, isA<TerminalDriver>());
      expect(d!.info.id, 'terminal:aider');
    });
  });

  group('session', () {
    test('plain paste folds newlines, then a separate Return', () async {
      final (s, pty) = await _open();
      await s.send('hi\nthere');
      expect(pty.texts, ['hi there', '\r']);
    });

    test('bracketed paste once the CLI asked for it, newlines kept', () async {
      final (s, pty) = await _open();
      pty.emit('\x1b[?2004h');
      await Future<void>.delayed(Duration.zero);
      await s.send('a\nb');
      expect(pty.texts, ['\x1b[200~a\nb\x1b[201~', '\r']);
    });

    test('events: user message, one notice, idle, history for late listeners, never running', () async {
      final (s, _) = await _open();
      await s.send('one');
      await s.send('two');
      await s.send('three');
      await s.close();
      final events = await s.events.toList();
      final messages = events.whereType<ChatMessage>().toList();
      expect(messages.where((m) => m.fromUser).map((m) => m.text), ['one', 'two', 'three']);
      expect(messages.where((m) => !m.fromUser), hasLength(1));
      final states = events.whereType<StateChange>().map((e) => e.executionStatus);
      expect(states, [ExecutionStatus.idle]);
    });

    test('interrupt is Ctrl-C; the rest are harmless', () async {
      final (s, pty) = await _open();
      await s.interrupt();
      expect(pty.writes.single, [3]);
      await s.respond(accept: true);
      await s.pause();
      await s.resume();
      await s.setMode(AgentMode.plan);
      expect(pty.writes, hasLength(1));
      await expectLater(s.rewindTo(null), throwsA(isA<HarnessError>()));
    });

    test('exit 0 finishes; another code is an error', () async {
      final (s, pty) = await _open();
      final seen = <HarnessEvent>[];
      s.events.listen(seen.add);
      pty.exit(0);
      await Future<void>.delayed(Duration.zero);
      expect(seen.whereType<StateChange>().last.executionStatus, ExecutionStatus.finished);

      final (s2, pty2) = await _open();
      final seen2 = <HarnessEvent>[];
      s2.events.listen(seen2.add);
      pty2.exit(2);
      await Future<void>.delayed(Duration.zero);
      expect(seen2.whereType<ConversationFailure>().single.message, contains('code 2'));
      expect(seen2.whereType<StateChange>().last.executionStatus, ExecutionStatus.error);
    });

    test('briefing text comes from the reader, null without a briefing', () async {
      final (none, _) = await _open();
      expect(await none.briefingText(), isNull);
      String? root;
      final (s, _) = await _open(
        briefing: const DriverBriefing(mcpUrl: 'u', mcpToken: 't', skillDir: '/b/briefing/skills'),
        read: (r) async {
          root = r;
          return 'session text';
        },
      );
      expect(await s.briefingText(), 'session text');
      expect(root, '/b/briefing');
    });
  });

  test('programEnv makes the shell capture fit a terminal UI', () {
    final env = programEnv(
      {'PATH': '/x', 'TERM': 'dumb', 'NO_COLOR': '1', 'PAGER': 'cat', 'GIT_PAGER': 'cat'},
      {'A': 'b'},
      'tag-9',
    );
    expect(env, {'PATH': '/x', 'TERM': 'xterm-256color', 'A': 'b', sessionEnvVar: 'tag-9'});
  });
}
