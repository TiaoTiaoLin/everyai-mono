import 'package:every_ai/features/code/domain/bug_check.dart';
import 'package:every_ai/features/code/domain/phases.dart';
import 'package:flutter_test/flutter_test.dart';

// What bug_check keeps about a bug, now that it runs without phases.

void main() {
  test('repro paths and additive test edits', () {
    expect(BugCheckState.isReproPath('test/calc_test.dart'), isTrue);
    expect(BugCheckState.isReproPath('src/app.spec.ts'), isTrue);
    expect(BugCheckState.isReproPath('tests/test_calc.py'), isTrue);
    expect(BugCheckState.isReproPath('.everyai/scratch/repro.sh'), isTrue);
    expect(BugCheckState.isReproPath('.everyai/scratch/research/notes.md'), isFalse);
    expect(BugCheckState.isReproPath('lib/contest.dart'), isFalse);
    expect(BugCheckState.onlyAdded('a\nb\n', 'a\nx\nb\ny\n'), isTrue);
    expect(BugCheckState.onlyAdded('a\nb\n', 'a\nc\n'), isFalse);
  });

  test('changed repro files: edited or gone count, files that only gained lines do not', () {
    final s = BugCheckState(reproFiles: {'t/a_test.sh': 'd1', 't/b_test.sh': 'd2', 't/c_test.sh': 'd3'});
    final before = {'t/b_test.sh': 'x\n'};
    final after = {'t/b_test.sh': 'x\ny\n'};
    expect(
      s.changedReproFiles(
        {'t/a_test.sh': 'd1', 't/b_test.sh': 'changed'},
        before: (p) => before[p],
        after: (p) => after[p],
      ),
      ['t/c_test.sh'],
    );
    expect(s.changedReproFiles({'t/a_test.sh': 'other', 't/b_test.sh': 'd2', 't/c_test.sh': 'd3'}), ['t/a_test.sh']);
  });

  test('the state round-trips, and an old phases.json gives up its repro fields', () {
    final s = BugCheckState(reproCommand: 'sh t.sh', reproExpect: 'boom', reviews: 1, reproFiles: {'t.sh': 'd'});
    final back = BugCheckState.fromJson(s.toJson());
    expect((back.reproCommand, back.reproExpect, back.reviews), ('sh t.sh', 'boom', 1));
    expect(back.reproFiles, {'t.sh': 'd'});
    expect(back.reproduced, isTrue);
    final old = BugCheckState.fromJson({
      'bugfix': true,
      'phase': 'verify',
      'nudges': 1,
      'repro_by_user': true,
      'failed_fixes': 2,
    });
    expect((old.reproByUser, old.failedFixes, old.reproduced), (true, 2, true));
    expect(BugCheckState().toJson(), isEmpty);
  });

  test('the tool has no phase wording, and the legacy file still names it', () {
    expect(bugCheckSpec['name'], bugCheckTool);
    expect('${bugCheckSpec['description']}', isNot(contains('triage.\n')));
    expect('${bugCheckSpec['description']}', isNot(contains('move on to')));
    // phases.dart only reads the notes old sessions hold.
    expect(
      parsePhaseNote('<everyai-phase flow="max" phase="plan">\nWrite the plan.\n</everyai-phase>')?.phase,
      Phase.plan,
    );
  });
}
