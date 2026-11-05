import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/floor_advice.dart';
import 'package:every_ai/features/code/domain/rewind.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/permissions_providers.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

/// The first value of [p] that meets [cond], now or when it changes.
Future<T> _when<T>(ProviderContainer c, ProviderListenable<T> p, bool Function(T) cond) {
  final done = Completer<T>();
  final sub = c.listen<T>(p, (_, v) {
    if (cond(v) && !done.isCompleted) done.complete(v);
  }, fireImmediately: true);
  return done.future.whenComplete(sub.close);
}

/// An outside driver's session: the test plays its events and reads the
/// answers it got.
final class _Session implements HarnessSession {
  final _events = StreamController<HarnessEvent>.broadcast();
  final answers = <({bool accept, String? reason})>[];
  var _answered = Completer<({bool accept, String? reason})>();

  /// The next answer the controller gives.
  Future<({bool accept, String? reason})> get nextAnswer => _answered.future;
  final steered = <String>[];
  var _seq = 0;

  @override
  String get id => 'c1';
  @override
  Stream<HarnessEvent> get events => _events.stream;

  /// The agent asks to run [kind] [args] through its tool [tool].
  void ask(String tool, String kind, Map<String, Object?> args) {
    _events
      ..add(actionEvent(id: 'a${++_seq}', toolName: tool, kind: kind, args: args))
      ..add(stateEvent('s$_seq', ExecutionStatus.waitingForConfirmation));
  }

  void add(HarnessEvent e) => _events.add(e);

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    final a = (accept: accept, reason: reason);
    answers.add(a);
    if (!_answered.isCompleted) _answered.complete(a);
  }

  void forgetAnswers() {
    answers.clear();
    _answered = Completer();
  }

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    steered.add(text);
    if (!_sent.isCompleted) _sent.complete(text);
  }

  var _sent = Completer<String>();

  /// The next message sent from now on.
  Future<String> nextSend() => (_sent = Completer()).future;
  @override
  Future<void> interrupt() async => steered.add('(interrupt)');
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {}
  @override
  Future<void> switchLlm(SessionSpec spec) async {}
  final rewound = <String?>[];
  @override
  Future<void> rewindTo(String? head) async => rewound.add(head);
  @override
  Future<void> close() => _events.close();
}

/// [_Session] for a driver that takes one answer per call and runs each
/// call once it is allowed (OpenCode).
final class _PerCallSession extends _Session implements PerCallApprovals {
  final answeredIds = <List<String>?>[];

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) {
    answeredIds.add(callIds);
    return super.respond(accept: accept, reason: reason, callIds: callIds);
  }
}

/// The MCP host for outside sessions reopened here: hands out tokens, serves nothing.
final class _Host implements HostServer {
  var _n = 0;

  @override
  Future<HostToken> mint(String sessionId, HostTools tools) async =>
      (url: Uri.parse('http://127.0.0.1:9/mcp'), token: 'tok${++_n}');
  @override
  bool touch(String token) => true;
  @override
  Future<void> revoke(String token) async {}
  @override
  Future<void> revokeSession(String sessionId) async {}
  @override
  Future<void> stop() async {}
}

final class _TestDriver implements HarnessDriver {
  _TestDriver(this.id, this.session, {this.caps = const {DriverCap.approvals}});
  final String id;
  final _Session session;
  @override
  final Set<DriverCap> caps;

  @override
  DriverInfo get info => DriverInfo(id: id, label: 'Test CLI');
  @override
  Future<DriverStatus> detect() async => const DriverStatus(installed: true);
  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) async => session;
  @override
  Future<HarnessSession> attach(String conversationId) async => session;
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

void main() {
  // Reopening an outside session briefs it, which sets up the app-quit listener.
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late _Session session;
  late ProviderContainer container;

  /// A session on [harness] in [mode], connected, with the agent's events
  /// played by the test.
  Future<CodeSessionController> open(
    AgentMode mode, {
    String harness = 'test',
    List<String> deny = const [],
    Map<String, HarnessDriver> extra = const {},
    SessionWorktree? worktree,
    bool reopen = false,
  }) async {
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: tmp.path).toJson()]);
    // [reopen]: the session as the last run saved it (an app restart).
    if (!reopen) {
      prefs['code.sessions'] = jsonEncode([
        CodeSessionInfo(
          id: 's1',
          projectId: 'p1',
          title: 't',
          conversationId: 'c1',
          model: 'm',
          mode: mode,
          workingDir: worktree?.path ?? tmp.path,
          createdAt: DateTime(2026),
          harness: harness,
          worktree: worktree,
        ).toJson(),
      ]);
    }
    // The user turned on "Use my own installed CLIs" for the extra drivers that need it (Gemini).
    prefs['code.settings'] = jsonEncode({
      'global': {
        'ownClis': [
          for (final d in extra.values)
            if (d.info.needsConsent) d.info.id,
        ],
      },
    });
    if (deny.isNotEmpty) {
      prefs[CodePermissions.key] = jsonEncode({
        'global': {'allow': <String>[], 'deny': deny},
      });
    }
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        modelCatalogProvider.overrideWith(_FixedCatalog.new),
        codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
        hostServerProvider.overrideWithValue(_Host()),
        driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
        driverRegistryProvider.overrideWithValue(
          DriverRegistry({
            everyaiHarnessName: _TestDriver(everyaiHarnessName, session, caps: const {DriverCap.rewind}),
            'test': _TestDriver('test', session),
            ...extra,
          }),
        ),
      ],
    );
    container.listen(codeSessionProvider('s1'), (_, _) {});
    await _when(container, codeSessionProvider('s1').select((s) => s.connected), (bool c) => c);
    return container.read(codeSessionProvider('s1').notifier);
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('drivers-approvals');
    session = _Session();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({bool accept, String? reason})> answered() async {
    final a = await session.nextAnswer;
    await pumpEventQueue();
    expect(session.answers, hasLength(1));
    return a;
  }

  Future<List<ActionCall>> pending() async {
    final p = await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.isNotEmpty,
    );
    await pumpEventQueue();
    return p;
  }

  test('Full auto: an outside floor hit gets advice, then the user decides', () async {
    // Every outside driver with approvals answers per call.
    session = _PerCallSession();
    final controller = await open(AgentMode.fullAuto);
    session.ask('Bash', 'TerminalAction', {'command': 'rm -rf ~'});
    final a = await answered();
    expect(a.accept, isFalse);
    expect(a.reason, startsWith(floorAdviceLead));
    expect(a.reason, contains(floorReason('rm -rf ~')!));
    // The model asks the user and runs it again: now it waits on the card, with the warning.
    session.forgetAnswers();
    session.add(resultEvent(id: 'r1', actionId: 'a1', toolName: 'Bash', text: a.reason!));
    session.ask('Bash', 'TerminalAction', {'command': 'rm -rf ~'});
    final waiting = await pending();
    expect(session.answers, isEmpty);
    final state = container.read(codeSessionProvider('s1'));
    expect(approvalFlags(controller.policy, waiting, state.mode), {waiting.single.id: floorReason('rm -rf ~')});
    await controller.approve(ApprovalScope.once, [waiting.single.id]);
    expect((await answered()).accept, isTrue);
  });

  test('Ask: an outside floor hit waits on the card with a warning', () async {
    session = _PerCallSession();
    final controller = await open(AgentMode.ask);
    session.ask('Bash', 'TerminalAction', {'command': 'rm -rf ~'});
    final waiting = await pending();
    expect(session.answers, isEmpty);
    expect(approvalFlags(controller.policy, waiting, AgentMode.ask).values, [floorReason('rm -rf ~')]);
  });

  test('a deny rule still refuses an outside floor hit outright', () async {
    session = _PerCallSession();
    await open(AgentMode.fullAuto, deny: ['rm *']);
    session.ask('Bash', 'TerminalAction', {'command': 'rm -rf ~'});
    final a = await answered();
    expect(a.accept, isFalse);
    expect(a.reason, contains('`rm *` forbids it'));
  });

  test('the EveryAI harness keeps the hard floor in Full auto', () async {
    session = _PerCallSession();
    await open(AgentMode.fullAuto, harness: everyaiHarnessName);
    session.ask('Bash', 'TerminalAction', {'command': 'rm -rf ~'});
    final a = await answered();
    expect(a.accept, isFalse);
    expect(a.reason, contains('never runs'));
  });

  test('Plan mode refuses an outside driver\'s changes', () async {
    await open(AgentMode.plan);
    session.ask('Bash', 'TerminalAction', {'command': 'npm install'});
    final a = await answered();
    expect((a.accept, a.reason), (false, AgentMode.planRefusal));
  });

  test('Ask mode runs reads at once and leaves the rest to the user', () async {
    await open(AgentMode.ask);
    session.ask('Bash', 'TerminalAction', {'command': 'ls'});
    expect((await answered()).accept, isTrue);
    session.forgetAnswers();
    session.add(resultEvent(id: 'r1', actionId: 'a1', toolName: 'Bash', text: 'README.md'));
    session.ask('Bash', 'TerminalAction', {'command': 'git push'});
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.isNotEmpty,
    );
    await pumpEventQueue();
    expect(session.answers, isEmpty);
  });

  test('a deny rule matches an outside driver\'s command', () async {
    await open(AgentMode.fullAuto, deny: ['git push *']);
    session.ask('Bash', 'TerminalAction', {'command': 'git push origin main'});
    final a = await answered();
    expect(a.accept, isFalse);
    expect(a.reason, contains('git push *'));
  });

  test('a tool of the driver\'s own is never approved on its own, even in Full auto', () async {
    await open(AgentMode.fullAuto);
    session.ask('Task', 'ClaudeTaskAction', {'prompt': 'look around'});
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.isNotEmpty,
    );
    await pumpEventQueue();
    expect(session.answers, isEmpty);
  });

  test('on the EveryAI harness the same kind still runs in Full auto', () async {
    await open(AgentMode.fullAuto, harness: everyaiHarnessName);
    session.ask('Task', 'ClaudeTaskAction', {'prompt': 'look around'});
    expect((await answered()).accept, isTrue);
  });

  test('a driver without rewind refuses before anything is stopped', () async {
    final controller = await open(AgentMode.ask);
    session.add(
      HarnessEvent.decode({
        'kind': 'MessageEvent',
        'id': 'm1',
        'source': 'user',
        'llm_message': {'role': 'user', 'content': 'hi'},
      }),
    );
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.items),
      (List<Object> i) => i.isNotEmpty,
    );
    final out = await controller.rewind(1);
    expect(out.kind, RewindKind.failed);
    expect(out.message, contains("Test CLI can't go back"));
    expect(session.steered, isEmpty);
  });

  group('saving from Files', () {
    String file() {
      final f = File('${tmp.path}/a.txt')..writeAsStringSync('one\n');
      return f.path;
    }

    test('writes when the agent is idle; a file changed on disk asks first', () async {
      final controller = await open(AgentMode.ask);
      final path = file();
      expect((await controller.saveFile(path, 'two\n', expected: 'one\n')).kind, SaveKind.saved);
      expect(File(path).readAsStringSync(), 'two\n');
      // Opened when it said "one": someone wrote "two" since.
      expect((await controller.saveFile(path, 'three\n', expected: 'one\n')).kind, SaveKind.changedOnDisk);
      expect(File(path).readAsStringSync(), 'two\n');
      expect((await controller.saveFile(path, 'three\n', expected: 'one\n', overwrite: true)).kind, SaveKind.saved);
      expect(File(path).readAsStringSync(), 'three\n');
    });

    test("a path outside the session's folder is refused", () async {
      final controller = await open(AgentMode.ask);
      final outside = await Directory.systemTemp.createTemp('files-outside');
      addTearDown(() => outside.delete(recursive: true));
      final f = File('${outside.path}/x.txt')..writeAsStringSync('x');
      final out = await controller.saveFile(f.path, 'y', expected: 'x');
      expect(out.kind, SaveKind.refused);
      expect(f.readAsStringSync(), 'x');
      // Nor through a link inside it.
      Link('${tmp.path}/link.txt').createSync(f.path);
      expect((await controller.saveFile('${tmp.path}/link.txt', 'y', expected: 'x')).kind, SaveKind.refused);
      expect(f.readAsStringSync(), 'x');
    });

    test('refused while the agent works, waits on an approval, or has a message queued', () async {
      final controller = await open(AgentMode.ask);
      final path = file();
      Future<SaveOutcome> save() => controller.saveFile(path, 'two\n', expected: 'one\n');

      session.add(stateEvent('s-run', ExecutionStatus.running));
      await _when(container, codeSessionProvider('s1').select((s) => s.transcript.running), (bool r) => r);
      final running = await save();
      expect((running.kind, running.reason), (SaveKind.refused, CodeSessionController.agentWorking));

      session.ask('Bash', 'TerminalAction', {'command': 'npm install'});
      await pending();
      expect((await save()).kind, SaveKind.refused);
      await controller.send('and then the tests');
      expect(container.read(codeSessionProvider('s1')).queued, hasLength(1));
      expect((await save()).kind, SaveKind.refused);
      expect(File(path).readAsStringSync(), 'one\n');
    });
  });

  group('rewind on an outside lead with a worktree', () {
    Future<String> git(String dir, List<String> args) async {
      final r = await Process.run('git', ['-C', dir, ...args]);
      if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
      return '${r.stdout}'.trim();
    }

    late String repo;
    late SessionWorktree w;

    setUp(() async {
      repo = '${tmp.path}/app';
      await Directory(repo).create(recursive: true);
      await git(repo, ['init', '-q', '-b', 'main']);
      await git(repo, ['config', 'user.name', 'Dev']);
      await git(repo, ['config', 'user.email', 'dev@example.com']);
      File('$repo/README.md').writeAsStringSync('# App\n');
      await git(repo, ['add', '-A']);
      await git(repo, ['commit', '-q', '-m', 'Initial commit']);
      w = await GitService.createWorktree(
        repoRoot: repo,
        slug: 'rewind-test',
        worktreesDir: '${tmp.path}/worktrees/app',
        hooksDir: '${tmp.path}/hooks',
      );
    });

    /// Sends [text] through the controller and echoes back what the harness got, as the drivers do.
    Future<void> turn(CodeSessionController controller, String id, String text) async {
      await controller.send(text);
      final turns = container.read(codeSessionProvider('s1')).transcript.items.whereType<UserTurn>().length;
      session.add(
        HarnessEvent.decode({
          'kind': 'MessageEvent',
          'id': id,
          'source': 'user',
          'llm_message': {'role': 'user', 'content': session.steered.last},
        }),
      );
      await _when(
        container,
        codeSessionProvider('s1').select((s) => s.transcript.items.whereType<UserTurn>().length),
        (int n) => n > turns,
      );
    }

    test('checkpoints are taken on hidden refs only', () async {
      final head = await git(repo, ['rev-parse', 'HEAD']);
      final branches = await git(repo, ['branch', '--list']);
      final status = await git(repo, ['status', '--porcelain']);
      final controller = await open(AgentMode.fullAuto, worktree: w);
      await turn(controller, 'm1', 'Add a file');
      File('${w.path}/one.txt').writeAsStringSync('1');
      await turn(controller, 'm2', 'Add another');
      expect(await git(repo, ['rev-parse', '--verify', checkpointRef(w, 2)]), isNotEmpty);
      expect(await git(repo, ['rev-parse', 'HEAD']), head);
      expect(await git(repo, ['branch', '--list']), branches);
      expect(await git(repo, ['status', '--porcelain']), status);
      expect(await git(w.path, ['rev-parse', 'HEAD']), w.baseCommit);
    });

    test('the files go back, the harness keeps the turns and hears about it once', () async {
      final controller = await open(AgentMode.fullAuto, worktree: w);
      await turn(controller, 'm1', 'Add a file');
      await turn(controller, 'm2', 'Add a decrement method');
      File('${w.path}/new.txt').writeAsStringSync('made in turn 2');
      final out = await controller.rewind(2);
      expect((out.kind, out.files, out.conversation), (RewindKind.done, true, false));
      expect(out.label, contains('Test CLI still remembers'));
      expect(File('${w.path}/new.txt').existsSync(), isFalse);
      expect(session.rewound, isEmpty);
      expect(container.read(codeSessionProvider('s1')).transcript.items.whereType<UserTurn>(), hasLength(2));
      await turn(controller, 'm3', 'try again');
      expect(session.steered.last, contains('<everyai-rewind>'));
      expect(session.steered.last, contains('"Add a decrement method"'));
      // The echoed note stays out of the user's turn, so a later rewind quotes what they typed.
      final turns = container.read(codeSessionProvider('s1')).transcript.items.whereType<UserTurn>().toList();
      expect(turns.last.text, 'try again');
      await controller.rewind(3);
      await controller.send('and once more');
      expect(session.steered.last, contains('"try again"'));
      await controller.send('and again');
      expect(session.steered.last, isNot(contains('<everyai-rewind>')));
    });

    test('the note survives an app restart before the next message', () async {
      await open(AgentMode.fullAuto, worktree: w);
      final controller = container.read(codeSessionProvider('s1').notifier);
      await turn(controller, 'm1', 'Add a file');
      await turn(controller, 'm2', 'Add a decrement method');
      expect((await controller.rewind(2)).files, isTrue);
      container.dispose();
      session = _Session();
      final reopened = await open(AgentMode.fullAuto, worktree: w, reopen: true);
      await reopened.send('try again');
      expect(session.steered.last, contains('<everyai-rewind>'));
      expect(session.steered.last, contains('"Add a decrement method"'));
    });

    test('a message sent while the files go back waits for them and carries the note', () async {
      final controller = await open(AgentMode.fullAuto, worktree: w);
      await turn(controller, 'm1', 'Add a file');
      await turn(controller, 'm2', 'Add a decrement method');
      File('${w.path}/new.txt').writeAsStringSync('made in turn 2');
      final sent = session.steered.length;
      final next = session.nextSend();
      final rewinding = controller.rewind(2);
      await controller.send('try again');
      // It waits for the files and goes out once the rewind is done.
      expect(session.steered, hasLength(sent));
      await rewinding;
      final text = await next;
      expect(session.steered.skip(sent), hasLength(1));
      expect(text, contains('<everyai-rewind>'));
      expect(text, endsWith('try again'));
      expect(File('${w.path}/new.txt').existsSync(), isFalse);
    });

    test('a save while the files go back is refused, and Files is read-only until they are', () async {
      final controller = await open(AgentMode.fullAuto, worktree: w);
      await turn(controller, 'm1', 'Add a file');
      await turn(controller, 'm2', 'Add a decrement method');
      final readme = '${w.path}/README.md';
      final rewinding = controller.rewind(2);
      expect(container.read(codeSessionProvider('s1')).filesLocked, isTrue);
      final out = await controller.saveFile(readme, '# Edited\n', expected: '# App\n');
      expect((out.kind, out.reason), (SaveKind.refused, CodeSessionController.agentWorking));
      await rewinding;
      expect(container.read(codeSessionProvider('s1')).filesLocked, isFalse);
      expect(File(readme).readAsStringSync(), '# App\n');
    });

    test("a save from Files lands in the next turn's checkpoint: rewinding to that turn keeps it", () async {
      final controller = await open(AgentMode.fullAuto, worktree: w);
      await turn(controller, 'm1', 'Add a file');
      final readme = '${w.path}/README.md';
      final saved = await controller.saveFile(readme, '# Edited\n', expected: '# App\n');
      expect(saved.kind, SaveKind.saved);
      expect(File(readme).readAsStringSync(), '# Edited\n');
      await turn(controller, 'm2', 'Add a decrement method');
      File('${w.path}/new.txt').writeAsStringSync('made in turn 2');
      expect((await controller.rewind(2)).files, isTrue);
      expect(File('${w.path}/new.txt').existsSync(), isFalse);
      expect(File(readme).readAsStringSync(), '# Edited\n');
      expect((await controller.rewind(1)).files, isTrue);
      expect(File(readme).readAsStringSync(), '# App\n');
    });

    test('a driver with its own rewind takes the conversation back too', () async {
      final controller = await open(
        AgentMode.fullAuto,
        harness: 'native',
        worktree: w,
        extra: {
          'native': _TestDriver('native', session, caps: const {DriverCap.approvals, DriverCap.rewind}),
        },
      );
      await turn(controller, 'm1', 'Add a file');
      await turn(controller, 'm2', 'Add a decrement method');
      File('${w.path}/new.txt').writeAsStringSync('made in turn 2');
      final out = await controller.rewind(2);
      expect((out.kind, out.files, out.conversation), (RewindKind.done, true, true));
      expect(session.rewound, ['m1']);
      expect(File('${w.path}/new.txt').existsSync(), isFalse);
      await controller.send('try again');
      expect(session.steered.last, isNot(contains('<everyai-rewind>')));
    });
  });

  test('a mid-run message on a driver without steering interrupts and is sent again', () async {
    final controller = await open(AgentMode.ask);
    await controller.steer('use tabs');
    expect(session.steered.first, '(interrupt)');
    expect(session.steered.last, contains('use tabs'));
  });

  group('an ACP agent through the controller (replayed)', () {
    final channels = <ReplayChannel>[];
    setUp(channels.clear);

    /// The ACP driver on [script] (changed by [edit]), with conversation c1 on disk (agent session [acpSession]).
    Map<String, HarnessDriver> acp(
      String command,
      String script,
      String acpSession, {
      String Function(String script)? edit,
    }) {
      final dir = Directory('${tmp.path}/data/acp-sessions/c1')..createSync(recursive: true);
      File(
        '${dir.path}/meta.json',
      ).writeAsStringSync(jsonEncode({'acpSessionId': acpSession, 'cwd': tmp.path, 'sessionTag': 's1', 'mode': 'ask'}));
      return {
        'acp': AcpDriver(
          id: 'acp:$command',
          label: command,
          command: command,
          which: (c) async => '/usr/local/bin/$c',
          dataDir: () async => '${tmp.path}/data',
          connect:
              ({
                required String executable,
                required List<String> args,
                required String cwd,
                required String sessionTag,
                required String logPath,
                required Map<String, String> env,
              }) async {
                final text = File('test/fixtures/drivers/$script').readAsStringSync();
                final c = ReplayChannel(edit?.call(text) ?? text);
                channels.add(c);
                return c;
              },
        ),
      };
    }

    /// The option the app answered permission request 0 with, once it has.
    Future<Object?> answered0() async {
      for (var i = 0; i < 100 && !channels.single.sent.any((m) => m['id'] == 0); i++) {
        await pumpEventQueue();
      }
      final reply = channels.single.sent.firstWhere((m) => m['id'] == 0);
      return ((reply['result']! as Map)['outcome']! as Map)['optionId'];
    }

    const ses = 'ses_e5ad81ff1ffeGaamwMA9ctbrrE';

    /// Waits until the conversation's journal has written [status] (so the
    /// folder isn't deleted under a write).
    Future<void> journalled(String status) async {
      final f = File('${tmp.path}/data/acp-sessions/c1/events.jsonl');
      bool done() => f.existsSync() && f.readAsStringSync().contains('"value":"$status"');
      for (var i = 0; i < 200 && !done(); i++) {
        await pumpEventQueue();
      }
      expect(done(), isTrue);
    }

    test('Full auto on OpenCode runs in its asking build mode, so rm -rf ~ (the floor) waits on the card', () async {
      final controller = await open(
        AgentMode.fullAuto,
        harness: 'acp',
        extra: acp('opencode', 'opencode/perm_floor.jsonl', ses),
      );
      await controller.send('Clean up');
      await _when(
        container,
        codeSessionProvider('s1').select((s) => s.transcript.pending),
        (List<ActionCall> p) => p.isNotEmpty,
      );
      await pumpEventQueue();
      // OpenCode has no mode that runs everything, so the nearest asks (see nativeModeFor).
      expect(controller.state.nativeMode, 'build');
      expect(controller.state.mode, AgentMode.ask);
      expect(channels.single.sent.where((m) => m['id'] == 0 && m['method'] == null), isEmpty);
      await journalled('waiting_for_confirmation');
    });

    test("Ask runs OpenCode's ls at once, allowed once", () async {
      final controller = await open(
        AgentMode.ask,
        harness: 'acp',
        extra: acp('opencode', 'opencode/perm_read.jsonl', ses),
      );
      await controller.send('Look');
      expect(await answered0(), 'once');
      await channels.single.finished;
      channels.single.expectFinished();
      await journalled('finished');
    });

    test("Gemini's shell call waits for the user even in Full auto", () async {
      final controller = await open(
        AgentMode.fullAuto,
        harness: 'acp',
        // Reopened with a fresh briefing: our server and its new token go in session/load.
        extra: acp(
          'gemini',
          'gemini/exec_waits.jsonl',
          'gemini-session-1',
          edit: (t) => t.replaceFirst(
            '"mcpServers":[]',
            '"mcpServers":[{"type":"http","name":"everyai","url":"http://127.0.0.1:9/mcp",'
                '"headers":[{"name":"Authorization","value":"Bearer tok1"}]}]',
          ),
        ),
      );
      await controller.send('List');
      await _when(
        container,
        codeSessionProvider('s1').select((s) => s.transcript.pending),
        (List<ActionCall> p) => p.isNotEmpty,
      );
      await pumpEventQueue();
      channels.single.expectFinished();
      expect(channels.single.sent.where((m) => m['id'] == 0 && m['method'] == null), isEmpty);
      await journalled('waiting_for_confirmation');
    });
  });

  test('a call allowed and still running is not asked about again when the next call asks', () async {
    final perCall = session = _PerCallSession();
    final controller = await open(AgentMode.ask);
    perCall.ask('shell', 'TerminalAction', {'command': 'npm install'});
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.length == 1,
    );
    await controller.approve(ApprovalScope.once, ['a1']);
    // a1 runs; while it does, a2 asks.
    perCall
      ..add(stateEvent('r1', ExecutionStatus.running))
      ..ask('shell', 'TerminalAction', {'command': 'git push'});
    final s = await _when(
      container,
      codeSessionProvider('s1').select((s) => s),
      (CodeSessionState s) => s.transcript.pending.length == 2,
    );
    await pumpEventQueue();
    expect(s.transcript.pending.map((c) => c.id), ['a1', 'a2']);
    expect(container.read(codeSessionProvider('s1')).decided, {'a1': true});
    // Deny all refuses only a2, the one still undecided.
    await controller.deny('no');
    expect(container.read(codeSessionProvider('s1')).decided, {'a1': true, 'a2': false});
    // A result settles its own answer; the rest go when the run ends.
    perCall.add(resultEvent(id: 'r2', actionId: 'a1', toolName: 'shell', text: 'ok'));
    await pumpEventQueue();
    expect(container.read(codeSessionProvider('s1')).decided, {'a2': false});
    perCall.add(stateEvent('e', ExecutionStatus.idle));
    await pumpEventQueue();
    expect(container.read(codeSessionProvider('s1')).decided, isEmpty);
    expect(perCall.answeredIds, [
      ['a1'],
      null,
    ]);
  });
}
