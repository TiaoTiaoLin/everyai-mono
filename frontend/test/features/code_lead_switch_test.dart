import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent, userMessageEvent;
import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart' show sessionFileName;
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/handoff/handoff.dart';
import 'package:every_ai/features/code/handoff/handoff_store.dart';
import 'package:every_ai/features/code/handoff/lead_timeline.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fake_leads.dart';

const _resume = {DriverCap.approvals, DriverCap.resume};

/// What reached the network: an outside lead's handoff sends nothing (checked after each test, so a call the
/// app caught still fails it).
final _sent = <String>[];
final _noNetwork = MockClient((req) async {
  _sent.add('${req.method} ${req.url}');
  return http.Response('no network in this test', 599);
});

void main() {
  // The app-quit listener needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late Directory project;
  late FakeHost host;
  late Preferences prefs;
  late ProviderContainer container;
  late Map<String, FakeLeadDriver> drivers;

  ProviderContainer make() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(FixedCatalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
      driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
      hostServerProvider.overrideWithValue(host),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      gatewayKeysProvider.overrideWith((ref) => throw StateError('no gateway key for outside agents')),
      // A handoff asks no model and fetches nothing: any backend call fails the test.
      apiClientProvider.overrideWithValue(ApiClient(baseUrl: Uri.parse('http://backend/'), client: _noNetwork)),
    ],
  );

  FakeLeadDriver d(String id) => drivers[id]!;
  CodeSessions sessions() => container.read(codeSessionsProvider.notifier);
  CodeSessionInfo infoOf(String id) => sessions().byId(id)!;
  Transcript transcriptOf(String id) => container.read(codeSessionProvider(id)).transcript;

  Future<CodeSessionInfo> start({String harness = 'alpha'}) => sessions().start(
    project: container.read(codeProjectsProvider).single,
    prompt: 'Add dark mode',
    model: '',
    mode: AgentMode.ask,
    harness: harness,
  );

  Future<CodeSessionController> open(String id) async {
    container.listen(codeSessionProvider(id), (_, _) {});
    await whenValue(container, codeSessionProvider(id).select((s) => s.connected), (bool c) => c);
    return container.read(codeSessionProvider(id).notifier);
  }

  /// [lead]'s conversation plays a turn: the user's message (as sent), a reply, and idle.
  Future<void> turn(FakeLeadSession lead, String id, String reply) async {
    lead
      ..add(userMessageEvent('$id-u', lead.sent.last))
      ..add(agentMessageEvent('$id-a', reply))
      ..add(stateEvent('$id-s', ExecutionStatus.idle));
    await pumpEventQueue();
  }

  /// Alpha works on a turn, then stops on its usage limit.
  Future<(CodeSessionInfo, CodeSessionController)> limited() async {
    final info = await start();
    final c = await open(info.id);
    final a = d('alpha').latest!;
    await turn(a, 'a1', 'Added the toggle.');
    a
      ..add(usageLimitEvent('a2-limit', 'You hit your 5-hour limit.', resetsAt: DateTime.utc(2026, 11, 5, 3)))
      ..add(stateEvent('a2-s', ExecutionStatus.error));
    await pumpEventQueue();
    return (info, c);
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('code-lead-switch');
    project = await Directory('${tmp.path}/project').create();
    host = FakeHost();
    drivers = {
      everyaiHarnessName: FakeLeadDriver(everyaiHarnessName, label: 'EveryAI', caps: _resume),
      'alpha': FakeLeadDriver('alpha', label: 'Alpha', caps: _resume),
      'beta': FakeLeadDriver('beta', label: 'Beta', caps: _resume),
      'term': FakeLeadDriver('term', label: 'Term'),
      'off': FakeLeadDriver('off', label: 'Off', status: const DriverStatus(installed: true, signedIn: false)),
      'cli': FakeLeadDriver('cli', label: 'Consent', needsConsent: true),
    };
    prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = make();
  });

  tearDown(() async {
    final sent = [..._sent];
    _sent.clear();
    expect(sent, isEmpty, reason: 'an outside lead reached the network');
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('a usage limit is offered as a switch to the harnesses that are ready', () async {
    final (info, c) = await limited();
    final notice = transcriptOf(info.id).items.last as NoticeItem;
    expect(notice.limit?.resetsAt, DateTime.utc(2026, 11, 5, 3));
    expect(c.leadOffer?.message, 'You hit your 5-hour limit.');
    final statuses = await container.read(driverStatusesProvider.future);
    final ready = readyLeads(container.read(driverRegistryProvider).listed, statuses, const {}, current: info.harness);
    // Not signed in, and not allowed yet, are left out.
    expect([for (final l in ready) l.id], [everyaiHarnessName, 'beta', 'term']);
    expect([
      for (final l in readyLeads(container.read(driverRegistryProvider).listed, statuses, {'cli'}, current: 'alpha'))
        l.id,
    ], contains('cli'));
    c.waitForLimit();
    expect(c.leadOffer, isNull);
  });

  test('switching hands the new lead everything, and the transcript stays one timeline', () async {
    final (info, c) = await limited();
    final outcome = await c.switchLead('beta', run: true);
    expect(outcome.kind, HandoffKind.full);
    final b = d('beta');
    final first = b.specs.single.initialMessage!;
    expect(first, startsWith('<everyai-mode name="ask">${AgentMode.ask.instructions}'));
    expect(first, contains('$handoffOpen from="alpha" kind="full">'));
    expect(first, contains('Added the toggle.'));
    expect(first, endsWith(carryOnMessage('Alpha')));
    final now = infoOf(info.id);
    expect((now.harness, now.conversationId), ('beta', 'beta-c1'));
    expect(now.leads['alpha']?.conversationId, 'alpha-c1');
    expect(d('alpha').latest!.closed, isTrue);
    // Beta's briefing names only Beta: it is fixed for its conversation (the handoff names Alpha).
    expect(b.specs.single.briefing!.sessionSkill, contains('Beta'));
    expect(b.specs.single.briefing!.sessionSkill, isNot(contains('Alpha')));
    await turn(b.latest!, 'b1', 'Picked it up.');
    final items = transcriptOf(info.id).items;
    final turns = items.whereType<UserTurn>().toList();
    expect([for (final t in turns) t.lead], ['Alpha', 'Beta']);
    expect(turns.last.text, carryOnMessage('Alpha'));
    final card = items.whereType<NoticeItem>().last;
    expect(card.message, 'Handoff to Beta');
    expect(card.detail, startsWith(handoffOpen));
    expect(items.indexOf(card), lessThan(items.indexOf(turns.last)));
    expect(c.leadOffer, isNull);
    // What Alpha did is kept, with the handoff.
    final dir = await sessions().timelineDir(info.id);
    final timeline = await readTimeline(dir);
    expect([for (final s in timeline) (s.harness, s.conversationId)], [('alpha', 'alpha-c1')]);
    expect((await loadHandoffs(dir)).single.kind, HandoffKind.full);
  });

  test('a handoff asks no model and fetches nothing; the whole conversation waits in a file', () async {
    final (info, c) = await limited();
    final outcome = await http.runWithClient(() => c.switchLead('beta', run: true), () => _noNetwork);
    expect(outcome.failed, isFalse);
    final first = d('beta').specs.single.initialMessage!;
    final path = RegExp(r'<transcript>\n(.+)\n</transcript>').firstMatch(first)![1]!;
    expect(path, startsWith('.everyai/handoffs/'));
    final file = File('${project.path}/$path');
    expect(file.readAsStringSync(), contains('# Alpha (conversation alpha-c1)'));
    expect(file.readAsStringSync(), contains('Added the toggle.'));
    expect((await loadHandoffs(await sessions().timelineDir(info.id))).single.transcript, path);
    // The turn had finished before the limit: nothing to finish.
    expect(first, isNot(contains('<cut-turn>')));
    expect(first, endsWith(carryOnMessage('Alpha')));
  });

  test('a turn the limit cut off is finished by the new lead, which redoes nothing', () async {
    final info = await start();
    final c = await open(info.id);
    final a = d('alpha').latest!;
    a
      ..add(userMessageEvent('a1-u', a.sent.last))
      ..add(actionEvent(id: 'a1-c', toolName: 'Bash', kind: 'TerminalAction', args: {'command': 'flutter test'}))
      ..add(resultEvent(id: 'a1-r', actionId: 'a1-c', toolName: 'Bash', text: '2 tests failed'))
      ..add(usageLimitEvent('a1-limit', 'You hit your 5-hour limit.'))
      ..add(stateEvent('a1-s', ExecutionStatus.error));
    await pumpEventQueue();
    expect(c.leadOffer, isNotNull);
    await c.switchLead('beta', run: true);
    final first = d('beta').specs.single.initialMessage!;
    expect(first, contains('<cut-turn>'));
    expect(first, contains('Request:\nAdd dark mode'));
    expect(first, contains('flutter test'));
    expect(first, contains('2 tests failed'));
    expect(first, isNot(contains('<last-request>')));
    expect(first, endsWith(carryOnMessage('Alpha', cut: true)));
    final stored = (await loadHandoffs(await sessions().timelineDir(info.id))).single;
    expect(stored.cut?.request, 'Add dark mode');
  });

  test('going back reopens the old conversation with only what it missed', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Wrote the tests.');
    final outcome = await c.switchLead('alpha', run: true);
    expect(outcome.kind, HandoffKind.delta);
    final a = d('alpha');
    expect(a.specs, hasLength(1));
    expect(a.attached, ['alpha-c1']);
    final delta = a.latest!.sent.single;
    expect(delta, contains('kind="delta"'));
    expect(delta, contains('Wrote the tests.'));
    expect(delta, isNot(contains('Added the toggle.')));
    expect(infoOf(info.id).leads.keys, ['beta']);
    await pumpEventQueue();
    // Alpha's conversation replayed its old turn; it shows once.
    final items = transcriptOf(info.id).items;
    expect(items.whereType<AgentText>().where((t) => t.text == 'Added the toggle.'), hasLength(1));
    expect(items.whereType<NoticeItem>().map((n) => n.message), containsAllInOrder(['Handoff to Beta']));
  });

  test("a conversation that can't be reopened gets a new one with everything", () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Wrote the tests.');
    d('alpha').attachFails = true;
    final outcome = await c.switchLead('alpha', run: true);
    expect(outcome.kind, HandoffKind.full);
    expect(d('alpha').specs, hasLength(2));
    expect(infoOf(info.id).conversationId, 'alpha-c2');
    expect(d('alpha').specs.last.initialMessage, contains('Added the toggle.'));
  });

  test('a harness that cannot resume gets everything each time', () async {
    final (info, c) = await limited();
    await c.switchLead('term', run: true);
    await turn(d('term').latest!, 't1', 'Ran it.');
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Checked it.');
    final outcome = await c.switchLead('term', run: true);
    expect(outcome.kind, HandoffKind.full);
    expect(d('term').specs, hasLength(2));
    expect(d('term').attached, isEmpty);
    expect(infoOf(info.id).leads.keys, unorderedEquals(['alpha', 'beta']));
  });

  test('the session and its timeline survive a restart', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Picked it up.');
    container.dispose();
    container = make();
    await open(info.id);
    await pumpEventQueue();
    final items = transcriptOf(info.id).items;
    final shown = [
      for (final i in items)
        switch (i) {
          AgentText(:final text) => text,
          NoticeItem(:final message) => message,
          UserTurn(:final lead) => 'user@$lead',
          _ => '',
        },
    ].where((s) => s.isNotEmpty).toList();
    expect(shown, [
      'user@Alpha',
      'Added the toggle.',
      'You hit your 5-hour limit.',
      'Handoff to Beta',
      'user@Beta',
      'Picked it up.',
    ]);
  });

  test('a lead left before its handoff went out gets everything when it comes back', () async {
    final info = await start();
    final c = await open(info.id);
    await turn(d('alpha').latest!, 'a1', 'Added the toggle.');
    // Beta from the menu: its handoff waits for a message that never comes.
    await c.switchLead('beta', run: false);
    await c.switchLead('alpha', run: false);
    expect(infoOf(info.id).leads['beta']?.conversationId, '');
    final outcome = await c.switchLead('beta', run: true);
    expect(outcome.kind, HandoffKind.full);
    expect(d('beta').attached, isEmpty);
    expect(d('beta').specs.last.initialMessage, contains('Added the toggle.'));
  });

  test('a switch that fails leaves the old lead its token and briefing', () async {
    final (info, c) = await limited();
    final briefing = File('${tmp.path}/data/driver-sessions/${info.id}/briefing/$sessionFileName');
    expect(host.live[info.id], {'tok1'});
    d('beta').startFails = true;
    final outcome = await c.switchLead('beta', run: true);
    expect(outcome.failed, isTrue);
    final now = infoOf(info.id);
    expect((now.harness, now.conversationId), ('alpha', 'alpha-c1'));
    expect(now.leads, isEmpty);
    // Alpha still reaches EveryAI; only Beta's token went.
    expect(host.live[info.id], {'tok1'});
    expect(host.revokedSessions, isEmpty);
    expect(briefing.readAsStringSync(), contains('Alpha'));
    expect(briefing.readAsStringSync(), isNot(contains('Beta')));
    expect(d('alpha').latest!.closed, isFalse);
  });

  test('the old token goes once the new outside lead is up', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    expect(host.live[info.id], {'tok2'});
    expect(host.revoked, ['tok1']);
  });

  test('messages and edits during a switch wait for the new lead', () async {
    final (info, c) = await limited();
    final gate = d('beta').startGate = Completer<void>();
    final switching = c.switchLead('beta', run: true);
    await pumpEventQueue();
    expect(container.read(codeSessionProvider(info.id)).switching, isTrue);
    await c.send('Please also update the README');
    await c.steer('And the changelog');
    expect((await c.compact()).kind, CompactKind.busy);
    expect(d('alpha').latest!.sent.where((m) => m.contains('README') || m.contains('changelog')), isEmpty);
    expect(container.read(codeSessionProvider(info.id)).queued, hasLength(2));
    gate.complete();
    expect((await switching).kind, HandoffKind.full);
    final b = d('beta').latest!;
    expect(b.sent.single, isNot(contains('README')));
    expect(container.read(codeSessionProvider(info.id)).switching, isFalse);
    // Beta's first turn ends; the queued messages follow, one per turn.
    await turn(b, 'b1', 'Picked it up.');
    expect(b.sent.last, endsWith('Please also update the README'));
  });

  test('a message queued during a menu switch goes to the new lead with the handoff', () async {
    final info = await start();
    final c = await open(info.id);
    await turn(d('alpha').latest!, 'a1', 'Added the toggle.');
    final gate = d('beta').startGate = Completer<void>();
    final switching = c.switchLead('beta', run: false);
    await pumpEventQueue();
    await c.send('Now the docs');
    gate.complete();
    await switching;
    await pumpEventQueue();
    final sent = d('beta').latest!.sent.single;
    expect(sent, contains('$handoffOpen from="alpha"'));
    expect(sent, endsWith('Now the docs'));
    expect(d('alpha').latest!.sent.where((m) => m.contains('Now the docs')), isEmpty);
  });

  test('a failed close of the old lead still completes the switch', () async {
    final (info, c) = await limited();
    d('alpha').latest!.closeFails = true;
    final outcome = await c.switchLead('beta', run: true);
    expect(outcome.kind, HandoffKind.full);
    expect(infoOf(info.id).harness, 'beta');
    await turn(d('beta').latest!, 'b1', 'Picked it up.');
    expect(transcriptOf(info.id).items.whereType<AgentText>().map((t) => t.text), contains('Picked it up.'));
  });

  test('a device that starts mirroring gets every lead\'s turns, once', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    await turn(d('beta').latest!, 'b1', 'Wrote the tests.');
    List<String> said() => [
      for (final e in c.mirrorEvents)
        if (e case ChatMessage(fromUser: false, :final text)) text,
    ];
    expect(said(), ['Added the toggle.', 'Wrote the tests.']);
    await c.switchLead('alpha', run: true);
    await pumpEventQueue();
    expect(said(), ['Added the toggle.', 'Wrote the tests.']);
  });

  test('the session model round-trips, and old sessions load with one lead', () {
    final info = CodeSessionInfo(
      id: 's1',
      projectId: 'p1',
      title: 't',
      conversationId: 'b1',
      model: 'm',
      mode: AgentMode.ask,
      workingDir: '/p',
      createdAt: DateTime(2026),
      harness: 'beta',
      leads: const {'alpha': LeadRecord(conversationId: 'a1', model: 'x', effort: 'high')},
      pendingHandoff: '<everyai-handoff>…</everyai-handoff>',
    );
    final back = CodeSessionInfo.fromJson(jsonDecode(jsonEncode(info.toJson())) as Map<String, Object?>);
    expect(back.toJson(), info.toJson());
    expect(back.leads['alpha']?.effort, 'high');
    final old = info.toJson()
      ..remove('leads')
      ..remove('pending_handoff');
    final loaded = CodeSessionInfo.fromJson(old);
    expect(loaded.leads, isEmpty);
    expect((loaded.pendingHandoff, loaded.harness), ('', 'beta'));
    expect(info.copyWith(harness: 'alpha').harness, 'alpha');
  });

  test('a busy session switches only once it has stopped', () async {
    final info = await start();
    final c = await open(info.id);
    final a = d('alpha').latest!..add(stateEvent('r1', ExecutionStatus.running));
    await pumpEventQueue();
    expect((await c.switchLead('beta', run: false)).busy, isTrue);
    expect(d('beta').specs, isEmpty);
    a.onInterrupt = [stateEvent('r2', ExecutionStatus.idle)];
    final outcome = await c.switchLead('beta', run: false, stopFirst: true);
    expect(outcome.failed || outcome.busy, isFalse);
    expect(a.interrupts, 1);
    expect(infoOf(info.id).harness, 'beta');
  });

  test('switching from the menu sends the handoff with the next message', () async {
    final info = await start();
    final c = await open(info.id);
    await turn(d('alpha').latest!, 'a1', 'Added the toggle.');
    await c.switchLead('beta', run: false);
    final b = d('beta').latest!;
    expect(d('beta').specs.single.initialMessage, isNull);
    expect(b.sent, isEmpty);
    expect(infoOf(info.id).pendingHandoff, startsWith(handoffOpen));
    await c.send('Now the docs');
    final sent = b.sent.single;
    expect(sent, startsWith('<everyai-mode name="ask">${AgentMode.ask.instructions}'));
    expect(sent, contains('$handoffOpen from="alpha"'));
    expect(sent, endsWith('Now the docs'));
    expect(infoOf(info.id).pendingHandoff, isEmpty);
    b.add(userMessageEvent('b1-u', sent));
    await pumpEventQueue();
    final items = transcriptOf(info.id).items;
    expect(items.whereType<NoticeItem>().last.message, 'Handoff to Beta');
    expect(items.whereType<UserTurn>().last.text, 'Now the docs');
  });

  test('Max on the EveryAI harness becomes Thorough on an outside lead', () async {
    drivers[everyaiHarnessName]!.conversations['e1'] = FakeLeadSession(id: 'e1', replays: true);
    prefs['code.sessions'] = jsonEncode([
      CodeSessionInfo(
        id: 's1',
        projectId: 'p1',
        title: 't',
        conversationId: 'e1',
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.ask,
        workingDir: project.path,
        createdAt: DateTime(2026),
        harness: everyaiHarnessName,
        tier: HarnessTier.max,
        harnessMode: HarnessMode.bugFix,
      ).toJson(),
    ]);
    container.dispose();
    container = make();
    final c = await open('s1');
    await c.switchLead('beta', run: false);
    final info = infoOf('s1');
    expect((info.harness, info.tier, info.harnessMode), ('beta', HarnessTier.thorough, HarnessMode.build));
    expect(info.leads[everyaiHarnessName]?.model, 'anthropic/claude-sonnet-5.5');
    expect(d('beta').specs.single.phaseFlow, isNull);
  });

  test('deleting a switched session drops its timeline and briefings', () async {
    final (info, c) = await limited();
    await c.switchLead('beta', run: true);
    final dir = await sessions().timelineDir(info.id);
    expect(Directory(dir).existsSync(), isTrue);
    await sessions().remove(info.id);
    expect(Directory(dir).existsSync(), isFalse);
    expect(host.revokedSessions, contains(info.id));
  });

  test('a delta starts where it should even when another harness reuses event ids', () {
    final seg = (
      harness: 'alpha',
      conversationId: 'a',
      events: <HarnessEvent>[agentMessageEvent('u1', 'one'), agentMessageEvent('u2', 'two')],
    );
    const since = HandoffCoverage(conversationId: 'a', eventId: 'u2');
    expect(placedSince([seg], [agentMessageEvent('u3', 'x')], since), since);
    // Beta's counter also made a u2: the delta would start in the wrong place.
    expect(placedSince([seg], [agentMessageEvent('u2', 'x')], since), isNull);
    expect(placedSince([seg], const [], null), isNull);
  });

  test('a session that never switched keeps working as before', () async {
    final info = await start();
    final c = await open(info.id);
    await c.send('more');
    expect(d('alpha').latest!.sent.last, endsWith('more'));
    expect(infoOf(info.id).leads, isEmpty);
    expect(container.read(codeSettingsProvider).ownClis, isEmpty);
  });
}
