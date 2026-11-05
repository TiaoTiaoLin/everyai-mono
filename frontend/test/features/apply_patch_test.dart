import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/apply_patch.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/model_family.dart';
import 'package:every_ai/features/code/harness/everyai/prompt_io.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:flutter_test/flutter_test.dart';

String patch(List<String> lines) => ['*** Begin Patch', ...lines, '*** End Patch'].join('\n');

void main() {
  group('parsePatch / applyHunks', () {
    test('adds a file', () {
      final ops = parsePatch(patch(['*** Add File: src/new.py', '+print(1)', '+print(2)']));
      expect(ops.single, isA<AddFile>().having((o) => o.content, 'content', 'print(1)\nprint(2)\n'));
    });

    test('updates with context and an @@ anchor, whitespace-tolerant', () {
      const before = 'def a():\n    return 1\n\ndef b():\n    return 1   \n';
      final op =
          parsePatch(patch(['*** Update File: m.py', '@@ def b():', '-    return 1', '+    return 2'])).single
              as UpdateFile;
      expect(applyHunks(before, op.hunks), 'def a():\n    return 1\n\ndef b():\n    return 2\n');

      final ctx =
          parsePatch(
                patch([
                  '*** Update File: m.py',
                  '@@',
                  ' def a():',
                  '-  return 1', // indentation off: still found
                  '+    return 3',
                ]),
              ).single
              as UpdateFile;
      expect(applyHunks(before, ctx.hunks), startsWith('def a():\n    return 3\n'));
    });

    test('reads a move and a delete', () {
      final ops = parsePatch(
        patch(['*** Update File: a.txt', '*** Move to: b.txt', '@@', '-x', '+y', '*** Delete File: c.txt']),
      );
      expect((ops[0] as UpdateFile).moveTo, 'b.txt');
      expect(ops[1], isA<DeleteFile>());
    });

    test('a hunk whose lines are not in the file is an error', () {
      final op = parsePatch(patch(['*** Update File: a.txt', '@@', '-missing', '+y'])).single as UpdateFile;
      expect(() => applyHunks('one\ntwo\n', op.hunks, path: 'a.txt'), throwsA(isA<PatchError>()));
    });

    test('malformed patches are refused', () {
      expect(() => parsePatch('*** Add File: x\n+y'), throwsA(isA<PatchError>()));
      expect(() => parsePatch(patch(['*** Add File: x', 'no plus'])), throwsA(isA<PatchError>()));
      expect(() => parsePatch(patch(['what is this'])), throwsA(isA<PatchError>()));
    });
  });

  group('the apply_patch tool', () {
    late Directory tmp;
    late ToolRunner runner;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('patch');
      runner = ToolRunner(
        root: tmp.path,
        shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
        gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
        sessionTag: 't',
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('adds, updates (after a read), moves and deletes; one observation per file', () async {
      File('${tmp.path}/a.txt').writeAsStringSync('one\ntwo\nthree\n');
      File('${tmp.path}/gone.txt').writeAsStringSync('bye\n');
      await runner.run('read', {'file_path': 'a.txt'});
      await runner.run('read', {'file_path': 'gone.txt'});
      final out = await runner.run('apply_patch', {
        'patch': patch([
          '*** Add File: new/b.txt',
          '+hello',
          '*** Update File: a.txt',
          '*** Move to: c.txt',
          '@@',
          ' one',
          '-two',
          '+TWO',
          '*** Delete File: gone.txt',
        ]),
      });
      expect(out.isError, isFalse, reason: out.text);
      expect(File('${tmp.path}/new/b.txt').readAsStringSync(), 'hello\n');
      expect(File('${tmp.path}/c.txt').readAsStringSync(), 'one\nTWO\nthree\n');
      expect(File('${tmp.path}/a.txt').existsSync(), isFalse);
      expect(File('${tmp.path}/gone.txt').existsSync(), isFalse);
      final files = out.observation['files']! as List<Object?>;
      expect([for (final f in files) (f! as Map)['op']], ['add', 'move', 'delete']);
    });

    test('nothing is written unless every change applies, and edits need a read', () async {
      File('${tmp.path}/a.txt').writeAsStringSync('one\n');
      final unread = await runner.run('apply_patch', {
        'patch': patch(['*** Update File: a.txt', '@@', '-one', '+1']),
      });
      expect(unread.text, contains('read'));
      await runner.run('read', {'file_path': 'a.txt'});
      final bad = await runner.run('apply_patch', {
        'patch': patch(['*** Add File: b.txt', '+b', '*** Update File: a.txt', '@@', '-nope', '+1']),
      });
      expect(bad.isError, isTrue);
      expect(File('${tmp.path}/b.txt').existsSync(), isFalse);
      expect(File('${tmp.path}/a.txt').readAsStringSync(), 'one\n');
    });
  });

  test('familyOf', () {
    expect(familyOf('anthropic/claude-sonnet-5.5'), ModelFamily.claude);
    expect(familyOf('openai/anthropic/claude-haiku-5.5'), ModelFamily.claude);
    expect(familyOf('openai/gpt-6.1-sol'), ModelFamily.gpt);
    expect(familyOf('gpt-5.4-mini'), ModelFamily.gpt);
    expect(familyOf('openai/o4-mini'), ModelFamily.gpt);
    expect(familyOf('openai/gpt-5-codex'), ModelFamily.gpt);
    expect(familyOf('google/gemini-3.5-flash'), ModelFamily.gemini);
    expect(familyOf('deepseek/deepseek-v4:free'), ModelFamily.open);
    expect(familyOf('moonshotai/kimi-k3'), ModelFamily.open);
    expect(familyOf('z-ai/glm-5'), ModelFamily.open);
    expect(familyOf('qwen/qwen4-coder'), ModelFamily.open);
    expect(familyOf('mistralai/devstral'), ModelFamily.other);
    expect(familyOf('google/gemma-4'), ModelFamily.other);
  });

  test('GPT gets apply_patch instead of edit and write; each family its rules block', () {
    List<String> names(List<Map<String, Object?>> specs) => [
      for (final s in specs) (s['function']! as Map)['name']! as String,
    ];
    final gpt = names(builtInToolSpecs(applyPatch: true));
    expect(gpt, contains('apply_patch'));
    expect(gpt, isNot(contains('edit')));
    expect(gpt, isNot(contains('write')));
    final claude = names(builtInToolSpecs());
    expect(claude, containsAll(['edit', 'write']));
    expect(claude, isNot(contains('apply_patch')));
    expect(familyRules(ModelFamily.claude), isNull);
    expect(familyRules(ModelFamily.other), isNull);
    for (final f in [ModelFamily.gpt, ModelFamily.gemini, ModelFamily.open]) {
      expect(familyRules(f), startsWith('<MODEL-NOTES>'));
    }
    expect(familyRules(ModelFamily.gpt), contains('apply_patch'));
  });

  group('permissions and transcript', () {
    ActionCall call(String patchText) => HarnessEvent.decode({
      'kind': 'ActionEvent',
      'id': 'p1',
      'tool_name': 'apply_patch',
      'tool_call_id': 'c1',
      'action': actionFor('apply_patch', {'patch': patchText}, '/work'),
    }) as ActionCall;

    final twoFiles = call(patch(['*** Add File: a.txt', '+a', '*** Update File: lib/b.dart', '@@', '-x', '+y']));

    test('apply_patch is an edit: Plan refuses, Ask asks, Auto-edit allows', () {
      const policy = PermissionPolicy(workingDir: '/work');
      expect(policy.decide(twoFiles, AgentMode.plan).source, DecisionSource.plan);
      expect(policy.decide(twoFiles, AgentMode.ask).verdict, Verdict.ask);
      expect(policy.decide(twoFiles, AgentMode.autoEdit).verdict, Verdict.allow);
      final outside = call(patch(['*** Add File: /etc/x.conf', '+a']));
      expect(policy.decide(outside, AgentMode.ask).verdict, Verdict.ask);
      expect(policy.decide(outside, AgentMode.fullAuto).verdict, Verdict.allow, reason: 'Full auto never asks');
    });

    test('an Edit rule allows a patch only when it covers every file', () {
      const libOnly = PermissionPolicy(
        workingDir: '/work',
        rules: PermissionRules(allow: ['Edit(lib/**)']),
      );
      expect(libOnly.decide(twoFiles, AgentMode.ask).verdict, Verdict.ask);
      const denyA = PermissionPolicy(
        workingDir: '/work',
        rules: PermissionRules(deny: ['Edit(a.txt)']),
      );
      expect(denyA.decide(twoFiles, AgentMode.fullAuto).verdict, Verdict.deny);
    });

    test('the transcript shows one edit step per file, each with its diff', () {
      final b = TranscriptBuilder()
        ..add(twoFiles)
        ..add(
          HarnessEvent.decode({
            'kind': 'ObservationEvent',
            'id': 'r1',
            'action_id': 'p1',
            'tool_name': 'apply_patch',
            'observation': {
              'content': [
                {'type': 'text', 'text': 'Applied'},
              ],
              'files': [
                {'path': '/work/a.txt', 'op': 'add', 'old_content': '', 'new_content': 'a\n'},
                {'path': '/work/lib/b.dart', 'op': 'update', 'old_content': 'x\n', 'new_content': 'y\n'},
              ],
            },
          }),
        );
      final steps = b.snapshot.items.whereType<StepItem>().toList();
      expect(steps, hasLength(2));
      expect(stepTitle(steps[0].step.call), 'Wrote /work/a.txt');
      expect(stepTitle(steps[1].step.call), 'Edited /work/lib/b.dart');
      expect(steps[1].step.result?.observation['new_content'], 'y\n');
      expect(steps.every((s) => s.step.done), isTrue);
    });
  });
}
