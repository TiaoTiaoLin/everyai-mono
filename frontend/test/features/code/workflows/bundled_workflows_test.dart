import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/script_io.dart' show findDeno;
import 'package:every_ai/features/code/workflows/workflow_bridge.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_journal.dart';
import 'package:every_ai/features/code/workflows/workflow_meta.dart';
import 'package:every_ai/features/code/workflows/workflow_prelude.dart' show workflowCtxKey;
import 'package:flutter_test/flutter_test.dart';

// The bundled workflow files in a real Deno, against a launcher whose
// agents answer by label. Skipped without Deno (set DENO_BIN, or
// tool/fetch_deno.sh).

/// Agents that answer with [answers] by label prefix, as a fenced json block.
final class _Agents implements AgentLauncher {
  _Agents(this.answers);
  final Map<String, Object? Function(WorkflowAgentCall call)> answers;
  final calls = <WorkflowAgentCall>[];
  final _byChild = <String, WorkflowAgentCall>{};

  WorkflowAgentCall byLabel(String label) => calls.firstWhere((c) => c.label == label);
  List<String> get labels => [for (final c in calls) c.label];

  @override
  Future<WorkflowChild> start(WorkflowAgentCall call) async {
    calls.add(call);
    final id = 'c${calls.length}';
    _byChild[id] = call;
    return (childId: id, harness: call.harness ?? 'lead', model: call.model ?? 'lead-model', note: null);
  }

  @override
  Future<WorkflowAgentResult> watch(String childId, {bool reattached = false}) async {
    final call = _byChild[childId]!;
    final answer = answers.entries.where((e) => call.label.startsWith(e.key)).firstOrNull?.value;
    if (answer == null) return (text: '', error: 'no answer for ${call.label}', spentMicros: null);
    final v = answer(call);
    // null: this agent fails.
    if (v == null) return (text: '', error: '${call.label} failed', spentMicros: null);
    return (text: v is String ? v : 'Done.\n```json\n${jsonEncode(v)}\n```', error: null, spentMicros: null);
  }

  @override
  Future<WorkflowAgentResult> followUp(String childId, String text) => watch(childId);

  @override
  Future<String?> finish(String childId, {required bool ok}) async => null;

  @override
  void stop(String childId) {}
}

String _source(String id) => File('assets/workflows/$id.js').readAsStringSync();

Map<String, Object?> _review(String verdict, [List<Map<String, Object?>> findings = const []]) => {
  'findings': findings,
  'verdict': verdict,
};

const _finding = {
  'severity': 'major',
  'file': 'lib/a.dart',
  'summary': 'drops the last item',
  'failure_scenario': 'a list of one',
  'suggested_fix': 'use <=',
};

void main() {
  final deno = findDeno();
  final skip = deno == null ? 'no deno (set DENO_BIN)' : false;
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('bundled-workflows'));
  tearDown(() => dir.delete(recursive: true));

  Future<WorkflowRun> run(String id, Map<String, Object?> args, _Agents agents, {Map<String, Object?>? ctx}) async {
    final bridge = await startWorkflowBridge(
      dir: '${dir.path}/s/run',
      source: _source(id),
      args: {...args, workflowCtxKey: ?ctx},
    );
    return WorkflowEngine(
      runId: 'r',
      name: id,
      bridge: bridge,
      launcher: agents,
      journal: WorkflowJournal.fresh((_) async {}),
    ).run();
  }

  test('each bundled file has a readable meta with its id, title, phases and args', () {
    for (final (id, title) in [('ultra', 'Ultra'), ('bugfix', 'Bug fix'), ('security_review', 'Security review')]) {
      final meta = parseWorkflowMeta(_source(id))!;
      expect(meta.id, id);
      expect(meta.name, title);
      expect(meta.description, isNotEmpty);
      expect(meta.whenToUse, isNotEmpty);
      expect(meta.args, startsWith('{'));
      expect(meta.phases, isNotEmpty);
    }
  });

  group('ultra', () {
    Map<String, Object? Function(WorkflowAgentCall)> answers({String verdict = 'fix-then-ship'}) => {
      'research:': (c) => {
        'note_path': '.everyai/workflows/runs/x/${c.label.split(':').last}.md',
        'plan': 'step 1',
        'simplicity': 'fine',
        'risks': <String>[],
        'tests': ['a_test'],
        'scope_change': '',
      },
      'impl:': (c) => {
        'commits': ['abc ${c.label}'],
        'summary': 'did it',
        'tests': 'pass',
        'deviations': '',
        'status': 'done',
      },
      'review:a:correctness': (_) => _review(verdict, verdict == 'ship' ? const [] : const [_finding]),
      'review:': (_) => _review('ship'),
      'refix:': (_) => {
        'fixed': ['drops the last item'],
        'rejected': <Object>[],
        'commits': ['def refix'],
        'tests': 'pass',
      },
      'integrate': (_) => 'All 12 tests pass.',
    };

    test('research, implement in worktrees, two reviews, refix, then one integration', () async {
      final agents = _Agents(answers());
      final end = await run(
        'ultra',
        {
          'items': [
            {'id': 'a', 'title': 'A', 'spec': 'Build A'},
            {'id': 'b', 'title': 'B', 'spec': 'Build B'},
          ],
        },
        agents,
        ctx: {
          'runId': 'run-1',
          'review': {'harness': 'everyai', 'model': 'openai/gpt-6.1'},
        },
      );
      expect(end.error, isNull);
      expect(end.status, WorkflowStatus.done);
      expect(end.phases, ['Research', 'Implement', 'Integrate']);
      expect(agents.labels.where((l) => l.startsWith('research:')), ['research:a', 'research:b']);
      expect(agents.labels.last, 'integrate');
      expect(agents.labels, containsAll(['review:a:correctness', 'review:a:cost-simplicity', 'refix:a']));
      expect(agents.labels, isNot(contains('refix:b')));
      // Research and review are read-only and stay in the session's folder; writers get worktrees.
      for (final c in agents.calls) {
        expect(c.worktree, c.label.startsWith('impl:') || c.label.startsWith('refix:'), reason: c.label);
      }
      expect(agents.byLabel('research:a').prompt, contains('read-only'));
      expect(agents.byLabel('research:a').prompt, contains('.everyai/workflows/runs/run-1/a.md'));
      expect(agents.byLabel('review:a:correctness').prompt, contains('read-only'));
      // Reviews run on the review model the app picked.
      expect(agents.byLabel('review:b:correctness').model, 'openai/gpt-6.1');
      expect(agents.byLabel('review:b:correctness').harness, 'everyai');
      expect(agents.byLabel('impl:a').model, isNull);
      final result = end.result! as Map;
      final items = (result['items'] as List).cast<Map<String, Object?>>();
      expect([for (final i in items) i['id']], ['a', 'b']);
      expect(items.first['commits'], ['abc impl:a', 'def refix']);
      expect(items.last['refix'], isNull);
      expect(result['integration'], 'All 12 tests pass.');
      expect(result['reviewed_on'], 'openai/gpt-6.1');
    }, skip: skip);

    test('a ship verdict skips the refix, and no review model reviews on the lead\'s', () async {
      final agents = _Agents(answers(verdict: 'ship'));
      final end = await run('ultra', {
        'items': [
          {'id': 'a', 'spec': 'Build A'},
        ],
      }, agents);
      expect(end.status, WorkflowStatus.done);
      expect(agents.labels, isNot(contains('refix:a')));
      expect(agents.byLabel('review:a:correctness').model, isNull);
      expect((end.result! as Map)['reviewed_on'], "a fresh agent on the lead's model");
    }, skip: skip);

    test(
      'a failed review keeps the other lens on its findings; a failed refix and integration keep the work',
      () async {
        final agents = _Agents({
          // Before the spread: answers match by the first prefix that fits.
          'review:a:cost-simplicity': (_) => _review('fix-then-ship', const [_finding]),
          ...answers(),
          // The correctness review fails: the other lens's finding must still be its own.
          'review:a:correctness': (_) => null,
          'refix:': (_) => null,
          'integrate': (_) => null,
        });
        final end = await run('ultra', {
          'items': [
            {'id': 'a', 'spec': 'Build A'},
          ],
        }, agents);
        expect(end.error, isNull);
        expect(end.status, WorkflowStatus.done);
        final result = end.result! as Map;
        final item = (result['items'] as List).single as Map;
        expect([for (final f in item['findings'] as List) (f as Map)['lens']], ['cost-simplicity']);
        expect(item['commits'], ['abc impl:a']);
        expect((item['refix'] as Map)['failed'], isNotNull);
        expect(result['integration'], isNull);
        expect(result['integration_error'], isNotNull);
      },
      skip: skip,
    );

    test('a whole task is split into items by a read-only agent first, then each is built', () async {
      final agents = _Agents({
        'split': (_) => {
          'items': [
            {'id': 'Dark Mode!', 'title': 'Dark mode', 'spec': 'Add a dark theme'},
            {'id': 'dark-mode', 'title': 'Export', 'spec': 'Add CSV export'},
            {'id': 'empty', 'title': 'Nothing', 'spec': ' '},
          ],
        },
        ...answers(verdict: 'ship'),
      });
      final end = await run('ultra', {'task': 'Add dark mode and CSV export'}, agents);
      expect(end.error, isNull);
      expect(end.phases.first, 'Split');
      final split = agents.byLabel('split');
      expect(split.readOnly, isTrue);
      expect(split.prompt, contains('Add dark mode and CSV export'));
      // Ids become unique slugs; an item without a spec is dropped.
      expect(agents.labels.where((l) => l.startsWith('impl:')), ['impl:dark-mode', 'impl:item-2']);
    }, skip: skip);

    test('a failed split builds the task as one item', () async {
      final agents = _Agents({'split': (_) => null, ...answers(verdict: 'ship')});
      final end = await run('ultra', {'task': 'Add dark mode'}, agents);
      expect(end.status, WorkflowStatus.done);
      expect(agents.labels.where((l) => l.startsWith('impl:')), ['impl:task']);
      expect(agents.byLabel('research:task').prompt, contains('Add dark mode'));
    }, skip: skip);

    test('missing items fail with a readable error', () async {
      final end = await run('ultra', {}, _Agents({}));
      expect(end.status, WorkflowStatus.failed);
      expect(end.error, contains('ultra needs args {items'));
      expect(end.error, contains('{task}'));
    }, skip: skip);
  });

  group('bugfix', () {
    Map<String, Object?> fix(String label) => {
      'repro_command': 'dart test test/a_test.dart',
      'cause': 'off by one',
      'fix_summary': 'uses <=',
      'verified': true,
      'files': ['lib/a.dart'],
      'commits': ['f00 $label'],
    };

    test('one fixer proves its steps with commands, the review model reviews, a refix follows a finding', () async {
      final agents = _Agents({
        'fix': (c) => fix(c.label),
        'review': (_) => _review('fix-then-ship', const [_finding]),
        'refix': (c) => fix(c.label),
      });
      final end = await run(
        'bugfix',
        {'bug': 'The last item is missing'},
        agents,
        ctx: {
          'review': {'harness': 'everyai', 'model': 'google/gemini-3.5-pro'},
        },
      );
      expect(end.error, isNull);
      expect(agents.labels, ['fix', 'review', 'refix']);
      expect(end.phases, ['Fix', 'Review', 'Refix']);
      final fixer = agents.byLabel('fix');
      expect(fixer.worktree, isTrue);
      // Workflow agents have no EveryAI host, so the proof is the commands' quoted output, and says so.
      expect(fixer.prompt, isNot(contains('bug_check')));
      expect(fixer.prompt, contains('The last item is missing'));
      for (final step in ['Reproduce', 'Verify', 'quote their output']) {
        expect(fixer.prompt, contains(step));
      }
      final review = agents.byLabel('review');
      expect(review.worktree, isFalse);
      expect(review.prompt, contains('read-only'));
      expect(review.model, 'google/gemini-3.5-pro');
      expect(review.prompt, contains('dart test test/a_test.dart'));
      expect(agents.byLabel('refix').worktree, isTrue);
      final result = end.result! as Map;
      expect(result['verified'], isTrue);
      expect(result['commits'], ['f00 fix', 'f00 refix']);
      expect((result['review'] as Map)['verdict'], 'fix-then-ship');
      expect(result['proof'], 'self-reported');
    }, skip: skip);

    test('a ship verdict skips the refix', () async {
      final agents = _Agents({'fix': (c) => fix(c.label), 'review': (_) => _review('ship')});
      final end = await run('bugfix', {'bug': 'Crash on save'}, agents);
      expect(end.status, WorkflowStatus.done);
      expect(agents.labels, ['fix', 'review']);
      expect((end.result! as Map)['refix'], isNull);
    }, skip: skip);

    test('a missing bug fails with a readable error', () async {
      final end = await run('bugfix', {'bug': 3}, _Agents({}));
      expect(end.status, WorkflowStatus.failed);
      expect(end.error, contains('bugfix needs args {bug}'));
    }, skip: skip);
  });

  group('security_review', () {
    Map<String, Object?> finding(String category, String summary) => {
      'severity': 'high',
      'file': 'lib/net.dart',
      'category': category,
      'summary': summary,
      'exploit': 'send a crafted URL',
      'fix': 'check the host',
    };

    test('a threat model, four read-only lenses, then only the verified findings come back', () async {
      final agents = _Agents({
        'threat-model': (_) => {
          'summary': 'adds a fetch tool',
          'entry_points': ['the url argument'],
          'boundaries': ['model to network'],
          'assets': <String>[],
          'files': ['lib/net.dart'],
        },
        'lens:data': (_) => {
          'findings': [finding('ssrf', 'fetches loopback addresses'), finding('dos', 'no size limit')],
        },
        'lens:': (_) => {'findings': <Object>[]},
        'verify': (_) => {
          'findings': [finding('ssrf', 'fetches loopback addresses')],
          'dropped': [
            {'summary': 'no size limit', 'reason': 'the client caps responses at 4 MB'},
          ],
        },
      });
      final end = await run('security_review', {'base': 'main'}, agents);
      expect(end.error, isNull);
      expect(end.phases, ['Threat model', 'Lenses', 'Verify']);
      expect(agents.labels.first, 'threat-model');
      expect(agents.labels.sublist(1, 5).toSet(), {'lens:secrets', 'lens:injection', 'lens:access', 'lens:data'});
      expect(agents.labels.last, 'verify');
      for (final c in agents.calls) {
        expect(c.worktree, isFalse, reason: c.label);
        expect(c.readOnly, isTrue, reason: c.label);
        expect(c.prompt, contains('You are read-only'), reason: c.label);
        expect(c.prompt, contains('git diff main...HEAD'), reason: c.label);
      }
      expect(agents.byLabel('lens:access').prompt, contains('adds a fetch tool'));
      expect(agents.byLabel('verify').prompt, contains('no size limit'));
      final result = end.result! as Map;
      expect([for (final f in result['findings'] as List) (f as Map)['summary']], ['fetches loopback addresses']);
      expect((result['dropped'] as List).single, containsPair('summary', 'no size limit'));
      expect(result['verified'], isTrue);
    }, skip: skip);

    test('a failed lens leaves the others\' labels right; a failed verify returns the findings unverified', () async {
      final agents = _Agents({
        'threat-model': (_) => {
          'summary': 's',
          'entry_points': <String>[],
          'boundaries': <String>[],
          'assets': <String>[],
          'files': <String>[],
          'base': 'abc1234def',
        },
        'lens:secrets': (_) => null,
        'lens:injection': (_) => {
          'findings': [finding('sql', 'builds SQL from input')],
        },
        'lens:': (_) => {'findings': <Object>[]},
        'verify': (_) => null,
      });
      final end = await run('security_review', {}, agents);
      expect(end.error, isNull);
      final result = end.result! as Map;
      expect(result['verified'], isFalse);
      expect([for (final f in result['findings'] as List) (f as Map)['lens']], ['injection']);
      // The base the threat model found: a plain diff, no substitution for the others.
      for (final c in agents.calls.skip(1)) {
        expect(c.prompt, contains('git diff abc1234def...HEAD'), reason: c.label);
        expect(c.prompt, isNot(contains(r'$(')), reason: c.label);
      }
    }, skip: skip);

    test('a focus from the user is quoted into the threat model and the lenses', () async {
      final agents = _Agents({
        'threat-model': (_) => {
          'summary': 's',
          'entry_points': <String>[],
          'boundaries': <String>[],
          'assets': <String>[],
          'files': <String>[],
        },
        'lens:': (_) => {'findings': <Object>[]},
      });
      final end = await run('security_review', {'focus': 'the upload endpoint'}, agents);
      expect(end.status, WorkflowStatus.done);
      for (final c in agents.calls) {
        expect(c.prompt, contains('```\nthe upload endpoint\n```'), reason: c.label);
      }
      final bad = await run('security_review', {'focus': 3}, _Agents({}));
      expect(bad.status, WorkflowStatus.failed);
    }, skip: skip);

    test('no candidate findings skips the verify step; a bad base is refused', () async {
      final agents = _Agents({
        'threat-model': (_) => {
          'summary': 's',
          'entry_points': <String>[],
          'boundaries': <String>[],
          'assets': <String>[],
          'files': <String>[],
        },
        'lens:': (_) => {'findings': <Object>[]},
      });
      final end = await run('security_review', {}, agents);
      expect(end.status, WorkflowStatus.done);
      expect(agents.labels, isNot(contains('verify')));
      expect((end.result! as Map)['findings'], isEmpty);
      expect(agents.byLabel('threat-model').prompt, contains('git merge-base'));

      final bad = await run('security_review', {'base': 'main; rm -rf /'}, _Agents({}));
      expect(bad.status, WorkflowStatus.failed);
      expect(bad.error, contains('a git ref'));
    }, skip: skip);
  });
}
