import 'dart:io';

import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/codex/codex_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/everyai_driver.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_driver.dart';
import 'package:every_ai/features/code/drivers/terminal/terminal_driver.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/everyai.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/session_processes.dart' show driverRootsOf;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _refProvider = Provider<Ref>((ref) => ref);

Future<String?> _nowhere(String command) async => null;

SessionSpec _spec(String dir) => SessionSpec(
  workingDir: dir,
  model: 'm',
  mode: AgentMode.ask,
  llmBaseUrl: 'http://127.0.0.1:9/v1',
  llmApiKey: 'sk-test',
  sessionTag: 't',
);

/// A session that records what the policy asks of it.
final class _Session implements HarnessSession, SteersRuns {
  final calls = <String>[];

  @override
  String get id => 's';
  @override
  Stream<HarnessEvent> get events => const Stream.empty();
  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async => calls.add('send $text');
  @override
  Future<void> interrupt() async => calls.add('interrupt');
  @override
  Future<void> steer(String text, {List<String> images = const []}) async => calls.add('steer $text');
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {}
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {}
  @override
  Future<void> switchLlm(SessionSpec spec) async {}
  @override
  Future<void> rewindTo(String? head) async {}
  @override
  Future<void> close() async {}
}

final class _Detecting implements HarnessDriver {
  _Detecting(this.id, this.status);
  final String id;
  final Future<DriverStatus> Function() status;
  var detects = 0;

  @override
  DriverInfo get info => DriverInfo(id: id, label: id);
  @override
  Set<DriverCap> get caps => const {};
  @override
  Future<DriverStatus> detect() {
    detects++;
    return status();
  }

  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) => throw UnimplementedError();
  @override
  Future<HarnessSession> attach(String conversationId) => throw UnimplementedError();
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

void main() {
  group('registry', () {
    late ProviderContainer container;
    setUp(() => container = ProviderContainer(overrides: [harnessProvider.overrideWithValue(FakeHarness())]));
    tearDown(() => container.dispose());

    test('every planned driver is registered under its stored name', () {
      final r = container.read(driverRegistryProvider);
      expect(r.resolve('everyai'), isA<EveryAIDriver>());
      expect(r.resolve('claude-code'), isA<ClaudeDriver>());
      expect(r.resolve('codex'), isA<CodexDriver>());
      expect(r.resolve('opencode'), isA<OpenCodeDriver>());
      final gemini = r.resolve('gemini')! as AcpDriver;
      expect((gemini.info.needsConsent, gemini.command), (true, 'gemini'));
      expect(gemini.args, ['--acp']);
      expect(r.resolve('claude-code')!.info.needsConsent, isTrue);
      expect(r.resolve('codex')!.info.needsConsent, isFalse);
      final acp = r.resolve('acp:goose')!;
      expect(acp, isA<AcpDriver>());
      expect((acp.info.id, (acp as AcpDriver).command), ('acp:goose', 'goose'));
      expect(identical(r.resolve('acp:goose'), acp), isTrue);
      expect(r.resolve('terminal:aider'), isA<TerminalDriver>());
      expect(r.resolve('terminal:aider')!.info.id, 'terminal:aider');
      expect(r.resolve('acp:'), isNull);
      expect(r.resolve('nope'), isNull);
      expect([for (final d in r.listed) d.info.id], ['everyai', 'claude-code', 'codex', 'opencode', 'gemini']);
    });

    test('harnessFor goes through the registry; the demo and removed harnesses are unchanged', () async {
      final ref = container.read(_refProvider);
      expect(await harnessFor(ref, '/p', harness: 'codex'), isA<CodexDriver>());
      expect(await harnessFor(ref, '/p'), isA<EveryAIDriver>());
      expect(await harnessFor(ref, '${demoScheme}x', harness: 'codex'), same(container.read(harnessProvider)));
      await expectLater(
        harnessFor(ref, '/p', harness: 'openHands'),
        throwsA(isA<HarnessError>().having((e) => e.message, 'message', removedHarnessNotice)),
      );
      await expectLater(
        harnessFor(ref, '/p', harness: 'zed'),
        throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains('ran on zed, which this version'))),
      );
    });

    test('stub drivers say they are not built yet and refuse to start', () async {
      final stubs = <HarnessDriver>[ClaudeDriver(which: _nowhere), CodexDriver(which: _nowhere)];
      for (final d in stubs) {
        final s = await d.detect();
        expect((s.installed, s.problem), (false, 'Not built yet.'), reason: d.info.id);
        await expectLater(d.start(_spec('/p')), throwsA(isA<HarnessError>()), reason: d.info.id);
        await expectLater(d.attach('c'), throwsA(isA<HarnessError>()), reason: d.info.id);
        expect(await d.statuses(['c']), isEmpty);
      }
    });

    test('ACP agents: a command with spaces is split, OpenCode gets acp, each profile its caps', () async {
      final r = container.read(driverRegistryProvider);
      final dsh = r.resolve('acp:dsh --profile acp')! as AcpDriver;
      expect((dsh.resolved.executable, dsh.info.id), ('dsh', 'acp:dsh --profile acp'));
      expect(dsh.resolved.args, ['--profile', 'acp']);
      expect((r.resolve('acp:opencode')! as AcpDriver).resolved.args, ['acp']);
      final gemini = r.resolve('gemini')!;
      expect((gemini as AcpDriver).resolved.args, ['--acp', '--approval-mode', 'default']);
      expect(dsh.caps, {DriverCap.resume, DriverCap.approvals, DriverCap.perCallApprovals});
      expect(gemini.caps.containsAll({DriverCap.mcp, DriverCap.images, DriverCap.switchModel}), isTrue);
      expect(gemini.caps.intersection({DriverCap.usage, DriverCap.effort, DriverCap.steer}), isEmpty);
      final oc = r.resolve('acp:opencode')!;
      expect(oc.caps.containsAll({DriverCap.usage, DriverCap.effort, DriverCap.subagents}), isTrue);
      expect(oc.caps.intersection({DriverCap.steer, DriverCap.fork, DriverCap.rewind}), isEmpty);
    });

    test('an ACP agent reports whether it is signed in, and a missing one says so', () async {
      final d = AcpDriver(
        id: 'gemini',
        label: 'Gemini CLI',
        command: 'gemini',
        which: (_) async => '/bin/echo',
        signedIn: () async => false,
      );
      final s = await d.detect();
      expect(
        (s.installed, s.signedIn, s.problem),
        (true, false, 'Not signed in. Run `gemini` in a terminal and sign in.'),
      );
      final missing = await AcpDriver(id: 'acp:x', label: 'x', command: 'x', which: _nowhere).detect();
      expect((missing.installed, missing.problem), (false, null));
    });

    test('an ACP conversation with its files is idle; one without is unknown', () async {
      final tmp = await Directory.systemTemp.createTemp('acp-statuses');
      addTearDown(() => tmp.delete(recursive: true));
      Directory('${tmp.path}/acp-sessions/c1').createSync(recursive: true);
      File('${tmp.path}/acp-sessions/c1/meta.json').writeAsStringSync('{"acpSessionId":"a","cwd":"/w"}');
      final d = AcpDriver(id: 'acp:x', label: 'x', command: 'x', dataDir: () async => tmp.path);
      expect(await d.statuses(['c1', 'c2']), {'c1': ExecutionStatus.idle});
      await expectLater(d.attach('c2'), throwsA(isA<HarnessError>()));
    });

    test('a found CLI reports its path and version', () async {
      final s = await ClaudeDriver(which: (_) async => '/bin/echo').detect();
      expect((s.installed, s.path, s.version, s.problem), (true, '/bin/echo', '--version', 'Not built yet.'));
    });

    test('statuses are looked up once, kept, and again after invalidating', () async {
      final ok = _Detecting('a', () async => const DriverStatus(installed: true, version: '1.0'));
      final broken = _Detecting('b', () async => throw StateError('no PATH'));
      final c = ProviderContainer(
        overrides: [
          driverRegistryProvider.overrideWithValue(DriverRegistry({'a': ok, 'b': broken})),
        ],
      );
      addTearDown(c.dispose);
      final first = await c.read(driverStatusesProvider.future);
      expect(first['a']!.version, '1.0');
      expect(first['b']!.problem, contains('no PATH'));
      await c.read(driverStatusesProvider.future);
      expect(ok.detects, 1);
      c.invalidate(driverStatusesProvider);
      await c.read(driverStatusesProvider.future);
      expect(ok.detects, 2);
    });
  });

  group('the EveryAI driver', () {
    test('its caps match what its sessions implement, and it forks', () async {
      final tmp = await Directory.systemTemp.createTemp('everyai-driver');
      addTearDown(() => tmp.delete(recursive: true));
      final inner = EveryAIHarness(dataDir: () async => '${tmp.path}/data', gatewayKey: () async => 'sk-test');
      final driver = EveryAIDriver(inner);
      final session = await driver.start(_spec(tmp.path));
      addTearDown(session.close);
      expect(driver.caps.contains(DriverCap.perCallApprovals), session is PerCallApprovals);
      expect(driver.caps.contains(DriverCap.steer), session is SteersRuns);
      expect(driver.caps.contains(DriverCap.fork), isTrue);
      // Through the driver, a fork still starts from the parent's history.
      final fork = await forkSession(driver, session.id, _spec(tmp.path))!;
      await fork.close();
      expect((await driver.detect()).installed, isTrue);
    });
  });

  group('fallbacks', () {
    const info = DriverInfo(id: 'x', label: 'Tool');

    test('steer runs in place when the driver can, else interrupts and sends again', () async {
      final s = _Session();
      Future<void> steer(SteersRuns r) => r.steer('hi');
      Future<void> resend() => s.send('hi');
      await steerOrResend(s, {DriverCap.steer}, steer: steer, resend: resend);
      expect(s.calls, ['steer hi']);
      s.calls.clear();
      await steerOrResend(s, const {}, steer: steer, resend: resend);
      expect(s.calls, ['interrupt', 'send hi']);
    });

    test('rewind and fork refuse in plain words without the cap', () {
      expect(rewindRefusal(info, {DriverCap.rewind}), isNull);
      expect(
        rewindRefusal(info, const {}),
        "Tool can't go back to an earlier turn. Start a new session from here instead.",
      );
      expect(forkUnavailable(info).message, "Tool can't hand a session over to a fork yet.");
      expect(usesOurChildSessions(const {}), isTrue);
      expect(usesOurChildSessions({DriverCap.subagents}), isFalse);
    });

    test('only kinds the rules understand are decided without the user', () {
      ActionCall call(String kind, [String tool = 'Bash', Map<String, Object?> args = const {}]) =>
          actionEvent(id: 'a', toolName: tool, kind: kind, args: args);
      expect(autoDecidable(call('TerminalAction', 'Bash', {'command': 'ls'})), isTrue);
      expect(autoDecidable(call('FileEditorAction', 'Edit', {'command': 'str_replace', 'path': 'a.dart'})), isTrue);
      expect(autoDecidable(call('MCPToolAction', 'github_search')), isTrue);
      expect(autoDecidable(call('ClaudeTaskAction', 'Task')), isFalse);
      expect(autoDecidable(call('BrowserAction', 'browser')), isFalse);
    });

    test('a known kind without the fields its rules read asks the user', () {
      ActionCall call(String kind, Map<String, Object?> args) =>
          actionEvent(id: 'a', toolName: 'native', kind: kind, args: args);
      // A patch to an outside or denied path would pass on an empty list.
      expect(autoDecidable(call('ApplyPatchAction', {'patch': '*** Begin Patch'})), isFalse);
      expect(autoDecidable(call('ApplyPatchAction', {'patch': '*** Begin Patch', 'paths': <String>[]})), isFalse);
      expect(
        autoDecidable(
          call('ApplyPatchAction', {
            'paths': ['../../.ssh/authorized_keys'],
          }),
        ),
        isTrue,
      );
      // Claude Code's native key instead of ours.
      expect(autoDecidable(call('WriteFileAction', {'file_path': '/etc/hosts'})), isFalse);
      expect(autoDecidable(call('FileEditorAction', {'command': 'create', 'file_path': 'a'})), isFalse);
      expect(autoDecidable(call('EditAction', {'path': ''})), isFalse);
      expect(autoDecidable(call('ReadFileAction', {})), isFalse);
      expect(autoDecidable(call('TerminalAction', {'cmd': 'rm -rf /'})), isFalse);
    });

    test('event builders give the shapes the transcript reads', () {
      final a = actionEvent(id: 'a1', toolName: 'Bash', kind: 'TerminalAction', args: {'command': 'ls'});
      expect((a.actionKind, a.str('command'), a.toolCallId), ('TerminalAction', 'ls', 'a1'));
      final r = resultEvent(id: 'r1', actionId: 'a1', toolName: 'Bash', text: 'out', isError: true);
      expect((r.actionId, r.text, r.outcome), ('a1', 'out', ToolOutcome.error));
      expect(
        stateEvent('s1', ExecutionStatus.waitingForConfirmation).executionStatus,
        ExecutionStatus.waitingForConfirmation,
      );
    });
  });

  test('a line sent after the CLI died is dropped, not an uncaught pipe error', () async {
    final dir = Directory.systemTemp.createTempSync('driver_proc');
    addTearDown(() => dir.deleteSync(recursive: true));
    final p = await spawnDriver(
      executable: '/bin/sh',
      args: ['-c', 'exit 3'],
      cwd: dir.path,
      sessionTag: 'dead-cli',
      logPath: '${dir.path}/log/driver.log',
    );
    expect(await p.exitCode, 3);
    expect(driverRootsOf('dead-cli'), isEmpty);
    p.send('{"jsonrpc":"2.0","id":1,"result":{}}');
    await pumpEventQueue();
    await p.close();
  });
}
