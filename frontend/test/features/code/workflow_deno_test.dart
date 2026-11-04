import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/script_io.dart' show findDeno;
import 'package:every_ai/features/code/workflows/workflow_bridge.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_journal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workflow_fakes.dart';

// A real Deno run of a lane-batch-shaped workflow, against the fake
// launcher. Skipped without Deno (set DENO_BIN, or tool/fetch_deno.sh).

const _script = r'''
export const meta = { name: 'demo', description: 'A test workflow' }

phase('Research')
log('starting', { n: args.n })
const notes = await parallel([
  () => agent('a', { label: 'A' }),
  () => agent('fail'),
  () => agent('b', { schema: { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'] } }),
])
phase('Build')
console.log('notes', notes.length)
const piped = await pipeline(
  ['x', 'y'],
  async (it) => agent('s1-' + it),
  async (prev, it) => agent('s2-' + it + ' after ' + prev),
)
return { meta: meta.name, notes, piped, n: args.n }
''';

void main() {
  final deno = findDeno();

  test('a lane-batch-shaped file runs end to end', () async {
    final dir = await Directory.systemTemp.createTemp('workflow-deno');
    addTearDown(() => dir.delete(recursive: true));
    final launcher = FakeLauncher();
    final s2x = Completer<void>();
    launcher.reply = (call, turn) => switch (call.prompt) {
      'fail' => throw 'no luck',
      'b' => 'Here:\n```json\n{"ok": true}\n```',
      final p => p,
    };
    // Item y's first stage waits until item x is on its second: stages don't wait for each other.
    launcher.gate = (call) async {
      if (call.prompt.startsWith('s2-x')) s2x.complete();
      if (call.prompt == 's1-y') await s2x.future;
    };
    final bridge = await startWorkflowBridge(dir: '${dir.path}/s/run', source: _script, args: {'n': 3});
    final lines = <String>[];
    final end = await WorkflowEngine(
      runId: 'r',
      name: 'demo',
      bridge: bridge,
      launcher: launcher,
      journal: WorkflowJournal.fresh((l) async => lines.add(l)),
    ).run();
    expect(end.error, isNull);
    expect(end.status, WorkflowStatus.done);
    expect(end.result, {
      'meta': 'demo',
      'notes': [
        'a',
        null,
        {'ok': true},
      ],
      'piped': ['s2-x after s1-x', 's2-y after s1-y'],
      'n': 3,
    });
    expect(end.phases, ['Research', 'Build']);
    expect(end.logs.map((l) => l.text), containsAll(['starting {"n":3}', 'notes 3']));
    expect(end.agents.firstWhere((a) => a.label == 'A').phase, 'Research');
    // The run's files go when it ends; the Deno cache is shared.
    expect(Directory('${dir.path}/s/run').existsSync(), isFalse);
    expect(Directory('${dir.path}/cache').existsSync(), isTrue);
  }, skip: deno == null ? 'no deno (set DENO_BIN)' : false);

  test('a script that throws ends the run as failed with its message', () async {
    final dir = await Directory.systemTemp.createTemp('workflow-deno');
    addTearDown(() => dir.delete(recursive: true));
    final bridge = await startWorkflowBridge(dir: '${dir.path}/s/run', source: 'throw new Error("bad args")', args: {});
    final end = await WorkflowEngine(
      runId: 'r',
      name: 'demo',
      bridge: bridge,
      launcher: FakeLauncher(),
      journal: WorkflowJournal.fresh((l) async {}),
    ).run();
    expect(end.status, WorkflowStatus.failed);
    expect(end.error, 'bad args');
  }, skip: deno == null ? 'no deno (set DENO_BIN)' : false);
}
