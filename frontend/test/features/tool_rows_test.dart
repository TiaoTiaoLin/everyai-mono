import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/ui/syntax_spans.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart' show ToolRunStatus;
import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/chat/ui/tool_steps.dart';
import 'package:every_ai/features/chat/chat_providers.dart' show toolStatusLabel;
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/ui/transcript/transcript_items.dart';
import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

const _base = TextStyle(fontSize: 12);

/// Every leaf (text, color) in [span].
List<(String, Color?)> leaves(InlineSpan span, [TextStyle? inherited]) {
  final out = <(String, Color?)>[];
  void visit(InlineSpan s, TextStyle? up) {
    final style = up?.merge(s.style) ?? s.style;
    if (s is TextSpan) {
      if (s.text != null && s.text!.isNotEmpty) out.add((s.text!, style?.color));
      s.children?.forEach((c) => visit(c, style));
    }
  }

  visit(span, inherited);
  return out;
}

Color? colorOf(InlineSpan span, String text) => leaves(span).firstWhere((l) => l.$1.contains(text)).$2;

ActionCall call(String id, String kind, Map<String, Object?> args, {String tool = 'terminal'}) =>
    ActionCall(id: id, raw: const {}, toolName: tool, toolCallId: 'tc-$id', action: {'kind': kind, ...args});

ToolStep done(ActionCall c, {ToolOutcome outcome = ToolOutcome.ok, String output = 'ok'}) => ToolStep(
  c,
  ToolResult(
    id: 'r-${c.id}',
    raw: const {},
    actionId: c.id,
    toolName: c.toolName,
    observation: {
      'content': [
        {'type': 'text', 'text': output},
      ],
    },
    outcome: outcome,
  ),
);

Widget host(Widget child, {Brightness brightness = Brightness.light}) => m.MaterialApp(
  home: m.Material(
    child: EveryThemeScope(
      theme: EveryTheme.resolve(DesignLanguage.material, brightness),
      child: SingleChildScrollView(child: child),
    ),
  ),
);

void main() {
  setUp(clearSyntaxCache);

  group('syntax spans', () {
    test('shell commands color keywords, strings and plain words differently', () {
      final span = shellSpan('if true; then echo "hi"; fi', base: _base, brightness: Brightness.light);
      expect(span.toPlainText(), 'if true; then echo "hi"; fi');
      expect(colorOf(span, 'if'), githubLightSyntaxTheme['keyword']!.color);
      expect(colorOf(span, '"hi"'), githubLightSyntaxTheme['string']!.color);
      expect(colorOf(span, 'if'), isNot(colorOf(span, '"hi"')));
    });

    test('dark mode uses the dark palette', () {
      final span = shellSpan('echo "x"', base: _base, brightness: Brightness.dark);
      expect(colorOf(span, '"x"'), oneDarkSyntaxTheme['string']!.color);
    });

    test('JSON output is colored, plain output is not', () {
      const json = '{"name": "app", "count": 3}';
      expect(looksLikeJson(json), isTrue);
      final colored = outputSpan(json, base: _base, brightness: Brightness.light);
      expect(colored.toPlainText(), json);
      expect(colorOf(colored, '3'), githubLightSyntaxTheme['number']!.color);

      expect(looksLikeJson('{not json}'), isFalse);
      expect(looksLikeJson('All 3 tests passed'), isFalse);
      final plain = outputSpan('All 3 tests passed', base: _base, brightness: Brightness.light);
      expect(plain.children, isNull);
    });

    test('paths dim their folder and keep the file name', () {
      const muted = Color(0xFF888888);
      final span = pathSpan('lib/src/main.dart', base: _base, muted: muted);
      expect(leaves(span), [('lib/src/', muted), ('main.dart', null)]);
      expect(pathSpan('README.md', base: _base, muted: muted).children, isNull);
    });

    test('diff lines color by the file\'s language; unknown files stay plain', () {
      final dart = codeSpan('final x = 1;', languageForPath('lib/a.dart'), base: _base, brightness: Brightness.light);
      expect(colorOf(dart, 'final'), githubLightSyntaxTheme['keyword']!.color);
      final txt = codeSpan('final x = 1;', languageForPath('notes.txt'), base: _base, brightness: Brightness.light);
      expect(txt.children, isNull);
    });

    test('arguments render as JSON without the kind tag', () {
      final span = argumentsSpan(
        {'kind': 'MCPToolAction', 'query': 'flutter'},
        base: _base,
        brightness: Brightness.light,
      );
      expect(span.toPlainText(), contains('"query": "flutter"'));
      expect(span.toPlainText(), isNot(contains('kind')));
    });

    test('lastLine skips trailing blank lines', () {
      expect(lastLine('a\nb\n\n  \n'), 'b');
      expect(lastLine(''), '');
    });
  });

  group('step grouping', () {
    final c1 = done(call('1', 'TerminalAction', {'command': 'ls'}));
    final c2 = done(call('2', 'TerminalAction', {'command': 'pwd'}));
    final c3 = done(call('3', 'MCPToolAction', {}, tool: 'fetch'));
    final edit = done(call('4', 'FileEditorAction', {'command': 'str_replace', 'path': 'a.dart'}));
    final running = ToolStep(call('5', 'TerminalAction', {'command': 'dart test'}));

    test('three or more finished commands and tools fold into a run', () {
      final out = groupSteps([AgentText('t', 'hi'), StepItem(c1), StepItem(c2), StepItem(c3), StepItem(running)]);
      expect(out, hasLength(3));
      expect(out[0], isA<AgentText>());
      expect((out[1] as StepRun).steps.map((s) => s.call.id), ['1', '2', '3']);
      expect(out[2], isA<StepItem>());
      expect(stepRunSummary((out[1] as StepRun).steps), 'Ran 2 commands, used 1 tool');
    });

    test('edits and short runs stay on their own rows', () {
      final out = groupSteps([StepItem(c1), StepItem(c2), StepItem(edit), StepItem(c3)]);
      expect(out.every((o) => o is StepItem), isTrue);
      expect(out, hasLength(4));
    });

    testWidgets('a run shows its summary and a preview of the last step, and opens to each', (tester) async {
      await tester.pumpWidget(host(StepRunView(run: StepRun([c1, c2, c3]))));
      expect(find.text('Ran 2 commands, used 1 tool'), findsOneWidget);
      await tester.tap(find.text('Ran 2 commands, used 1 tool'));
      await tester.pump();
      expect(find.textContaining('ls'), findsWidgets);
      expect(find.textContaining('pwd'), findsWidgets);
    });

    testWidgets('a running command shows the working mark and colored command', (tester) async {
      await tester.pumpWidget(host(StepView(step: running)));
      expect(find.textContaining('dart test'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // stop the animation
    });
  });

  group('chat tool steps', () {
    test('labels follow the tool and its progress', () {
      expect(toolStepLabel('web_fetch', ToolRunStatus.running), 'Reading');
      expect(toolStepLabel('web_fetch', ToolRunStatus.done), 'Read');
      expect(toolStepLabel('generate_image', ToolRunStatus.failed), 'Couldn\'t create the image');
      expect(toolStepLabel('code_run', ToolRunStatus.done), 'Used code run');
      LiveToolStep long(ToolRunStatus status, [String? detail]) =>
          LiveToolStep(id: 's', name: 'summarise_parts', status: status, detail: detail);
      expect(toolStepLine(long(ToolRunStatus.running, 'part 14 of 40')), (
        label: 'Reading a long source · part 14 of 40…',
        detail: '',
      ));
      expect(toolStepLine(long(ToolRunStatus.running)).label, 'Reading a long source…');
      expect(toolStepLine(long(ToolRunStatus.done, 'part 40 of 40')).label, 'Read a long source');
      expect(toolStatusLabel('summarise_parts', 'part 2 of 9'), 'Reading a long source · part 2 of 9…');
      expect(
        toolStepLine(const LiveToolStep(id: 'f', name: 'web_fetch', status: ToolRunStatus.done, detail: 'https://a.b')),
        (label: 'Read', detail: 'https://a.b'),
      );
    });

    test('finished steps summarize', () {
      const steps = [
        LiveToolStep(id: 'a', name: 'web_fetch', status: ToolRunStatus.done),
        LiveToolStep(id: 'b', name: 'web_fetch', status: ToolRunStatus.done),
        LiveToolStep(id: 'c', name: 'generate_image', status: ToolRunStatus.done),
      ];
      expect(toolRunSummary(steps), 'Read 2 pages, created 1 image');
    });

    test('URL details show the host and dim the path', () {
      const muted = Color(0xFF777777);
      final span = toolDetailSpan('https://dart.dev/guides/x', base: _base, muted: muted);
      expect(leaves(span), [('dart.dev', null), ('/guides/x', muted)]);
      expect(toolDetailSpan('a red fox', base: _base, muted: muted).toPlainText(), 'a red fox');
    });

    testWidgets('finished steps fold; the running one keeps its own row', (tester) async {
      await tester.pumpWidget(
        host(
          const LiveToolSteps(
            steps: [
              LiveToolStep(id: 'a', name: 'web_fetch', status: ToolRunStatus.done, detail: 'https://a.dev/1'),
              LiveToolStep(id: 'b', name: 'web_fetch', status: ToolRunStatus.done, detail: 'https://b.dev/2'),
              LiveToolStep(id: 'c', name: 'web_fetch', status: ToolRunStatus.running, detail: 'https://c.dev/3'),
            ],
          ),
        ),
      );
      expect(find.text('Read 2 pages'), findsOneWidget);
      expect(find.text('Reading'), findsOneWidget);
      expect(find.textContaining('a.dev'), findsNothing);
      await tester.tap(find.text('Read 2 pages'));
      await tester.pump();
      expect(find.textContaining('a.dev'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
