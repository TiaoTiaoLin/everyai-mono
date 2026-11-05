import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/workflows/bug_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a report with no symptom is vague; one that names one, or code, or is long, is not', () {
    for (final vague in ['', '  ', 'fix it', 'the button', 'please look at the login']) {
      expect(bugLooksVague(vague), isTrue, reason: vague);
    }
    for (final concrete in [
      'Saving crashes',
      'TypeError in parse()',
      'lib/notes/save.dart',
      'Login returns 500',
      'When I open the settings page twice in a row the list of models is shown in the old order',
    ]) {
      expect(bugLooksVague(concrete), isFalse, reason: concrete);
    }
  });

  test('the card asks what goes wrong, the steps and what should happen; the last two may be not sure', () {
    expect(bugQuestions, hasLength(3));
    expect(bugQuestions.first.options, isEmpty);
    expect([for (final q in bugQuestions.skip(1)) q.options.single.label], ['Not sure', 'Not sure']);
  });

  test('the answers follow the original report; empty ones are left out', () {
    expect(
      bugWithAnswers('the button', const [
        QuestionAnswer(other: 'Tapping Save shows a blank screen'),
        QuestionAnswer(),
        QuestionAnswer(selected: {0}),
      ]),
      'the button\nWhat goes wrong: Tapping Save shows a blank screen\nExpected: Not sure',
    );
    expect(bugWithAnswers('', const [QuestionAnswer(other: 'It hangs')]), 'What goes wrong: It hangs');
  });
}
