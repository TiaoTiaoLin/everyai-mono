import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/ui/session_view.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:every_ai/features/questions/ui/question_card.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  final args = {
    'questions': [
      for (final h in ['Platform', 'Review', 'Fields', 'Address'])
        {
          'question': 'Which $h?',
          'header': h,
          'multi_select': h == 'Fields',
          'options': [
            {'label': '$h A', 'description': 'first'},
            {'label': '$h B', 'description': 'second'},
          ],
        },
    ],
  };
  final call = HarnessEvent.decode({
    'kind': 'ActionEvent',
    'id': 'q',
    'tool_name': 'ask_user_question',
    'action': args,
  }) as ActionCall;
  final item = QuestionItem(call, Question.listFrom(args));

  Widget host(ValueChanged<List<QuestionAnswer>> onSubmit) => m.MaterialApp(
    home: m.Material(
      child: EveryThemeScope(
        theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
        child: SingleChildScrollView(
          child: QuestionCard(questions: item.questions, onSubmit: onSubmit),
        ),
      ),
    ),
  );

  testWidgets('a long questionnaire pages through its questions and submits them together', (tester) async {
    List<QuestionAnswer>? sent;
    await tester.pumpWidget(host((a) => sent = a));

    expect(find.text('1 of 4'), findsOneWidget);
    expect(find.text('Which Platform?'), findsOneWidget);
    expect(find.text('Which Review?'), findsNothing);

    // A single-choice pick moves on to the next question.
    await tester.tap(find.text('Platform B'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 4'), findsOneWidget);

    // Number keys pick options on the current page.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(find.text('Which Fields?'), findsOneWidget);
    expect(find.text('Select all that apply'), findsOneWidget);

    // Multi-select stays on the page; Next moves on.
    await tester.tap(find.text('Fields A'));
    await tester.tap(find.text('Fields B'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Still to answer: Address'), findsOneWidget);

    await tester.tap(find.text('Address A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit answers'));
    await tester.pump();

    expect(sent!.map((a) => a.selected), [
      {1},
      {0},
      {0, 1},
      {0},
    ]);
  });

  testWidgets('the recommended option shows a tag instead of its "(Recommended)" suffix', (tester) async {
    final questions = Question.listFrom({
      'questions': [
        {
          'question': 'Which database?',
          'options': [
            {'label': 'Postgres (Recommended)', 'description': 'Relational, runs anywhere'},
            {'label': 'SQLite', 'description': 'One file, no server'},
          ],
        },
      ],
    });
    expect(questions.single.options.map((o) => (o.shownLabel, o.recommended)), [('Postgres', true), ('SQLite', false)]);
    await tester.pumpWidget(
      m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: QuestionCard(questions: questions, onSubmit: (_) {}),
          ),
        ),
      ),
    );
    expect(find.text('Recommended'), findsOneWidget);
    expect(find.textContaining('(Recommended)'), findsNothing);
    expect(find.text('Relational, runs anywhere'), findsOneWidget);
  });

  group('a long typed answer', () {
    final one = Question.listFrom({
      'questions': [
        {
          'question': 'Anything else?',
          'options': [
            {'label': 'No', 'description': ''},
          ],
        },
      ],
    });
    final long = List.filled(30, 'the answer goes on').join(' ');

    Widget narrow(Widget card) => m.MaterialApp(
      home: m.Material(
        child: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
          child: Center(
            child: SizedBox(width: 320, child: SingleChildScrollView(child: card)),
          ),
        ),
      ),
    );

    testWidgets('wraps in a growing Other box, and Enter still submits', (tester) async {
      List<QuestionAnswer>? sent;
      await tester.pumpWidget(narrow(QuestionCard(questions: one, onSubmit: (a) => sent = a)));
      final field = find.byType(m.TextField);
      final before = tester.getSize(field).height;
      await tester.enterText(field, long);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(field).height, greaterThan(before));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(sent?.single.other, long);
    });

    testWidgets('wraps in the answered summary', (tester) async {
      await tester.pumpWidget(
        narrow(
          QuestionCard(
            questions: one,
            onSubmit: (_) {},
            answers: [QuestionAnswer(other: long)],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(long), findsOneWidget);
    });
  });

  testWidgets('tabs jump between questions', (tester) async {
    await tester.pumpWidget(host((_) {}));
    await tester.tap(find.text('Address'));
    await tester.pumpAndSettle();
    expect(find.text('4 of 4'), findsOneWidget);
    expect(find.text('Which Address?'), findsOneWidget);
  });

  testWidgets('the card keeps its page while the transcript grows around it', (tester) async {
    final builder = TranscriptBuilder()
      ..add(
        HarnessEvent.decode({
          'kind': 'MessageEvent',
          'id': 'u1',
          'source': 'user',
          'llm_message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        }),
      )
      ..add(call);
    Widget list() => m.MaterialApp(
      home: m.Material(
        child: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
          child: TranscriptList(
            transcript: builder.snapshot,
            mode: AgentMode.ask,
            onAnswer: (_, _) {},
            onRewind: null,
            onApprovePlan: () {},
            onRevisePlan: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );

    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(list());
    await tester.tap(find.text('Address'));
    await tester.pumpAndSettle();
    expect(find.text('4 of 4'), findsOneWidget);

    // New rows arrive after the card; the card must not reset to page 1.
    for (var i = 0; i < 3; i++) {
      builder.add(
        HarnessEvent.decode({
          'kind': 'MessageEvent',
          'id': 'm$i',
          'source': 'agent',
          'llm_message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'note $i'},
            ],
          },
        }),
      );
      await tester.pumpWidget(list());
      await tester.pump();
      expect(find.text('4 of 4'), findsOneWidget, reason: 'after event $i');
    }
  });
}
