import 'dart:io';

import 'package:every_ai/features/billing/billing_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/handoff/handoff.dart';
import 'package:every_ai/features/code/handoff/handoff_git.dart';
import 'package:every_ai/features/code/handoff/handoff_store.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart' show HarnessError;
import 'package:flutter_test/flutter_test.dart';

const _dir = '/p/app';

ChatMessage _user(String id, String text) => ChatMessage(id: id, raw: const {}, fromUser: true, text: text);
ChatMessage _agent(String id, String text) => ChatMessage(id: id, raw: const {}, fromUser: false, text: text);

ActionCall _call(String id, String tool, Map<String, Object?> action) =>
    ActionCall(id: id, raw: const {}, toolName: tool, toolCallId: 't$id', action: action);

ToolResult _result(String id, ToolOutcome outcome, {String text = 'ok', String reason = ''}) => ToolResult(
  id: 'r$id',
  raw: const {},
  actionId: id,
  toolName: 'x',
  outcome: outcome,
  observation: {
    'content': [
      {'type': 'text', 'text': text},
    ],
    if (reason.isNotEmpty) 'reason': reason,
  },
);

List<HarnessEvent> _write(String id, String path, [ToolOutcome outcome = ToolOutcome.ok]) => [
  _call(id, 'write', {'kind': 'WriteFileAction', 'file_path': '$_dir/$path'}),
  _result(id, outcome),
];

/// A session: a plan approved, todos, writes (one refused, one failed, one
/// .env), a second request and an open question card.
List<HarnessEvent> _session() => [
  _user('u1', modeNote(AgentMode.plan, 'Add a decrement method')),
  _call('p1', presentPlanTool, {
    'title': 'Decrement',
    'summary': 'Add decrement()',
    'steps': [
      {'title': 'Write it', 'detail': 'in lib/counter.dart'},
    ],
  }),
  _result('p1', ToolOutcome.rejected, reason: planApprovedReason),
  _call('k1', 'task_tracker', {
    'kind': 'TaskTrackerAction',
    'task_list': [
      {'title': 'Write decrement', 'status': 'done'},
      {'title': 'Test it', 'status': 'in_progress'},
    ],
  }),
  ..._write('w1', 'lib/counter.dart'),
  ..._write('w2', 'lib/refused.dart', ToolOutcome.rejected),
  ..._write('w3', 'lib/failed.dart', ToolOutcome.error),
  ..._write('w4', '.env'),
  _agent('a1', 'Done with the method.'),
  _user('u2', 'Now add tests'),
  ..._write('w5', 'test/counter_test.dart'),
  _call('q1', askUserQuestionTool, {
    'questions': [
      {
        'question': 'Which test runner?',
        'header': 'Runner',
        'options': [
          {'label': 'dart test', 'description': ''},
        ],
      },
    ],
  }),
  const UnknownEvent(id: 'x1', raw: {}, kind: 'ConversationStateUpdateEvent'),
];

Handoff _build(List<HarnessEvent> events, {HandoffCoverage? since, bool resumable = true}) => buildHandoff(
  events,
  from: 'claude',
  fromConversation: 'c1',
  to: 'codex',
  workingDir: _dir,
  since: since,
  resumable: resumable,
  now: DateTime.utc(2026, 11, 4, 10),
);

const _goodSummary =
    '## Objective\n- tests\n\n## Important details\n- none\n\n## Work state\n- half\n\n## Next move\n1. x';

void main() {
  test('facts come from the session: plan, todos, last request, open question, files newest first', () {
    final h = _build(_session());
    expect(h.kind, HandoffKind.full);
    expect(h.approvedPlan, startsWith('# Decrement'));
    expect(h.proposedPlan, isEmpty);
    expect(h.todos.map((t) => t.title), ['Write decrement', 'Test it']);
    expect(h.lastRequest, 'Now add tests');
    expect(h.openQuestions, ['Which test runner?']);
    expect(h.files.map((f) => f.path), ['test/counter_test.dart', '.env', 'lib/counter.dart']);
    expect(h.files[1].withheld, isTrue);
    // The state event after the card isn't something the model saw.
    expect(h.coverage.eventId, 'q1');
    expect(h.coverage.conversationId, 'c1');
    expect(h.recent, contains('[user]\nNow add tests'));
  });

  test('the first request carries no mode note', () {
    expect(_build(_session().sublist(0, 3)).lastRequest, 'Add a decrement method');
  });

  test('a delta has only what came after, while plan and todos still come from all of it', () {
    final h = _build(
      _session(),
      since: const HandoffCoverage(conversationId: 'c1', eventId: 'a1'),
    );
    expect(h.kind, HandoffKind.delta);
    expect(h.since?.eventId, 'a1');
    expect(h.recent, contains('Now add tests'));
    expect(h.recent, isNot(contains('Add a decrement method')));
    expect(h.files.map((f) => f.path), ['test/counter_test.dart']);
    expect(h.approvedPlan, startsWith('# Decrement'));
    expect(h.todos, hasLength(2));
    expect(handoffMessage(h), contains('kind="delta"'));
  });

  test('a stale delta becomes a full handoff, with the reason', () {
    final events = _session();
    final unknown = _build(
      events,
      since: const HandoffCoverage(conversationId: 'c0', eventId: 'gone'),
    );
    expect(unknown.kind, HandoffKind.full);
    expect(unknown.staleReason, contains('no longer in the session record'));
    final closed = _build(
      events,
      since: const HandoffCoverage(conversationId: 'c1', eventId: 'a1'),
      resumable: false,
    );
    expect(closed.kind, HandoffKind.full);
    expect(closed.staleReason, contains("can't be reopened"));
    expect(closed.since, isNull);

    final big = [...events, for (var i = 0; i < 40; i++) _agent('big$i', 'x' * 2000)];
    final h = _build(
      big,
      since: const HandoffCoverage(conversationId: 'c1', eventId: 'a1'),
    );
    expect(h.kind, HandoffKind.full);
    expect(h.staleReason, contains('too much happened'));
    expect(h.recent.length, lessThanOrEqualTo(handoffRecentChars + 40));
  });

  test('the message keeps its blocks in a fixed order, volatile last, empty ones left out', () {
    final h = _build(_session()).withSummary(_goodSummary, SummaryState.done);
    final m = handoffMessage(h, fromName: 'Claude Code');
    expect(
      m,
      startsWith('<everyai-handoff from="claude" kind="full">\nYou are taking over a coding session from Claude Code.'),
    );
    expect(m, endsWith(handoffClose));
    final order = [
      '<summary>',
      '<approved-plan>',
      '<todos>',
      '<open-questions>',
      '<files>',
      '<recent-turns>',
      '<last-request>',
    ];
    final at = [for (final t in order) m.indexOf(t)];
    expect(at, everyElement(greaterThanOrEqualTo(0)));
    expect([...at]..sort(), at);
    expect(m, contains('- [x] Write decrement\n- [~] Test it'));
    expect(m, contains('<file path=".env">\n(diff not shown'));
    expect(m, isNot(contains('<proposed-plan>')));
    expect(m, isNot(contains('<git>')));
    expect(handoffMessage(_build(_session())), isNot(contains('<summary>')));
  });

  group('summary', () {
    BillingSummary billing({int wallet = 0, int included = 0, int used = 0}) => BillingSummary.fromJson({
      'plan': {'id': 'free', 'name': 'Free', 'price_cents': 0, 'included_micros': included},
      'wallet_micros': wallet,
      'included_micros': included,
      'used_micros': used,
    });

    test('is paid for by a key or credits; unknown billing tries anyway', () {
      expect(handoffSummaryPayable(ownKey: false, billing: billing()), isFalse);
      expect(handoffSummaryPayable(ownKey: false, billing: billing(included: 10, used: 10)), isFalse);
      expect(handoffSummaryPayable(ownKey: true, billing: billing()), isTrue);
      expect(handoffSummaryPayable(ownKey: false, billing: billing(wallet: 1)), isTrue);
      expect(handoffSummaryPayable(ownKey: false), isTrue);
    });

    test('is skipped without a summarizer', () async {
      final h = await summarizeHandoff(_build(_session()), _session(), null);
      expect((h.summaryState, h.summary), (SummaryState.skipped, null));
    });

    test('a failed call or a junk reply leaves the facts', () async {
      final base = _build(_session());
      final refused = await summarizeHandoff(
        base,
        _session(),
        (_) async => throw const HarnessError('no', status: 402),
      );
      expect((refused.summaryState, refused.summary), (SummaryState.failed, null));
      expect(refused.approvedPlan, base.approvedPlan);
      final junk = await summarizeHandoff(base, _session(), (_) async => 'Sure!');
      expect(junk.summaryState, SummaryState.failed);
    });

    test('a good reply lands in the message, asked with the handoff focus', () async {
      List<Map<String, Object?>>? asked;
      final h = await summarizeHandoff(_build(_session()), _session(), (m) async {
        asked = m;
        return _goodSummary;
      });
      expect(h.summaryState, SummaryState.done);
      expect('${asked!.last['content']}', contains(handoffFocus));
      expect(handoffMessage(h), contains('<summary>\n## Objective'));
    });
  });

  group('on disk', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('everyai-handoff'));
    tearDown(() => tmp.delete(recursive: true));

    Future<String> git(String dir, List<String> args) async {
      final r = await Process.run('git', ['-C', dir, ...args]);
      if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
      return '${r.stdout}'.trim();
    }

    Future<String> repo() async {
      final repo = '${tmp.path}/app';
      await Directory('$repo/lib').create(recursive: true);
      await git(repo, ['init', '-q', '-b', 'main']);
      await git(repo, ['config', 'user.name', 'Dev']);
      await git(repo, ['config', 'user.email', 'dev@example.com']);
      File('$repo/lib/a.txt').writeAsStringSync('one\n');
      await git(repo, ['add', '-A']);
      await git(repo, ['commit', '-q', '-m', 'Initial commit']);
      return repo;
    }

    CodeSessionInfo info(String dir, {SessionWorktree? worktree, GitBaseline? baseline}) => CodeSessionInfo(
      id: 's1',
      projectId: 'p1',
      title: 't',
      conversationId: 'c1',
      model: 'm',
      mode: AgentMode.autoEdit,
      workingDir: dir,
      createdAt: DateTime.utc(2026),
      branch: worktree?.branch ?? baseline?.branch ?? '',
      worktree: worktree,
      baseline: baseline,
    );

    test('a worktree session: branch, changes, uncommitted files, commits, capped diffs', () async {
      final root = await repo();
      final w = await GitService.createWorktree(
        repoRoot: root,
        slug: 'decrement',
        worktreesDir: '${tmp.path}/worktrees',
        hooksDir: '${tmp.path}/hooks',
      );
      File('${w.path}/lib/a.txt').writeAsStringSync('one\ntwo\n');
      await git(w.path, ['commit', '-q', '-am', 'Add two']);
      File('${w.path}/lib/big.txt').writeAsStringSync('${List.generate(2000, (i) => 'line $i').join('\n')}\n');
      File('${w.path}/.env').writeAsStringSync('KEY=secret\n');

      final g = (await handoffGit(info(w.path, worktree: w)))!;
      expect(g.git.branch, w.branch);
      expect(g.git.worktree, w.path);
      expect(g.git.changes.map((c) => c.path).toSet(), {'lib/a.txt', 'lib/big.txt', '.env'});
      expect(g.git.uncommitted, 2);
      expect(g.git.commits, ['Add two']);

      // No writes in the events: the files come from git, the biggest first.
      final h = buildHandoff(
        [_user('u1', 'go')],
        from: 'codex',
        fromConversation: 'c1',
        to: 'claude',
        workingDir: w.path,
        git: g.git,
        diffs: g.diffs,
      );
      expect(h.files.first.path, 'lib/big.txt');
      expect(h.files.first.cut, isTrue);
      expect(h.files.first.diff.length, lessThan(handoffDiffChars + 100));
      expect(h.files.singleWhere((f) => f.path == '.env').withheld, isTrue);
      expect(handoffMessage(h), isNot(contains('KEY=secret')));
      expect(handoffMessage(h), contains('<git>'));
    });

    test('an in-place session counts commits from the commit it started on, not its snapshot tree', () async {
      final root = await repo();
      final base = (await GitService.baseline(root))!;
      File('$root/lib/a.txt').writeAsStringSync('one\nthree\n');
      await git(root, ['commit', '-q', '-am', 'Add three']);
      final g = (await handoffGit(info(root, baseline: base)))!;
      expect(g.git.commits, ['Add three']);
      expect(g.git.worktree, isEmpty);
      expect(g.git.changes.map((c) => c.path), ['lib/a.txt']);
    });

    test('handoffs round-trip, newest first; a harness resumes from the last handoff away from it', () async {
      final first = _build(_session());
      final back = buildHandoff(
        [..._session(), _user('u3', 'and docs')],
        from: 'codex',
        fromConversation: 'c2',
        to: 'claude',
        workingDir: _dir,
        now: DateTime.utc(2026, 11, 4, 11),
      ).withSummary(_goodSummary, SummaryState.done);
      await saveHandoff(tmp.path, first);
      await saveHandoff(tmp.path, back);
      File('${tmp.path}/handoffs/broken.json').writeAsStringSync('{');

      final loaded = await loadHandoffs(tmp.path);
      expect(loaded.map((h) => h.toHarness), ['claude', 'codex']);
      expect(loaded.first.toJson(), back.toJson());
      expect(loaded.last.toJson(), first.toJson());
      expect(lastSeenBy(loaded, 'claude')?.eventId, 'q1');
      expect(lastSeenBy(loaded, 'claude')?.conversationId, 'c1');
      expect(lastSeenBy(loaded, 'gemini'), isNull);
    });
  });
}
