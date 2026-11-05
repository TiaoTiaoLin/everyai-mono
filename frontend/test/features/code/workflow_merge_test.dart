import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/workflows/workflow_prelude.dart' show mergeFindingsJs;
import 'package:flutter_test/flutter_test.dart';

// mergeFindings is JavaScript (a workflow global), so these run it in node when there is one.

Future<Object?> _merge(List<Map<String, Object?>> findings) async {
  final dir = await Directory.systemTemp.createTemp('merge-findings');
  addTearDown(() => dir.delete(recursive: true));
  File('${dir.path}/m.js').writeAsStringSync(
    'const __g = globalThis;\n$mergeFindingsJs\nconsole.log(JSON.stringify(__g.mergeFindings(${jsonEncode(findings)})));',
  );
  final r = await Process.run('node', ['${dir.path}/m.js']);
  if (r.exitCode != 0) fail('${r.stderr}');
  return jsonDecode('${r.stdout}');
}

Map<String, Object?> _f(
  String lens,
  String summary, {
  String file = 'a.dart',
  String severity = 'minor',
  String? scenario,
}) => {'lens': lens, 'file': file, 'severity': severity, 'summary': summary, 'failure_scenario': ?scenario};

void main() {
  final hasNode = Process.runSync('which', ['node']).exitCode == 0;
  final skip = hasNode ? false : 'no node';

  test('the same problem from two lenses is one finding that names both', () async {
    final out = await _merge([
      _f('correctness', 'The loop never stops when the list is empty', severity: 'minor', scenario: 'short'),
      _f('simplicity', 'The loop never stops if the list is empty', severity: 'major', scenario: 'a longer scenario'),
    ]) as List;
    expect(out, hasLength(1));
    final m = out.single as Map;
    expect(m['severity'], 'major');
    expect(m['lenses'], ['correctness', 'simplicity']);
    expect(m['merged_from'], 2);
    expect(m['failure_scenario'], 'a longer scenario');
    expect(m['merged_summaries'], ['The loop never stops when the list is empty']);
  }, skip: skip);

  test('one lens is never merged with itself, and other files or other problems stay apart', () async {
    final same = 'The loop never stops when the list is empty';
    expect(await _merge([_f('a', same), _f('a', same)]), hasLength(2));
    expect(await _merge([_f('a', same), _f('b', same, file: 'b.dart')]), hasLength(2));
    expect(await _merge([_f('a', same), _f('b', 'Token is logged in plain text on failure')]), hasLength(2));
    expect(await _merge(<Map<String, Object?>>[]), isEmpty);
  }, skip: skip);

  test('the overlap threshold is 0.6 of the words', () async {
    // 2 shared words of 8 in all (0.25) stay apart; 3 of 4 (0.75) join.
    expect(
      await _merge([_f('a', 'cache keys collide across users'), _f('b', 'cache keys differ per tenant')]),
      hasLength(2),
    );
    expect(await _merge([_f('a', 'cache keys collide'), _f('b', 'cache keys collide often')]), hasLength(1));
  }, skip: skip);
}
