import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

final MarkdownStyle style = MarkdownStyle.fallback(Brightness.light);

Widget host(Widget child) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(800, 1200)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 600, child: child),
      ),
    ),
  );
}

Future<void> pumpMarkdown(
  WidgetTester tester,
  String data, {
  bool streaming = false,
  void Function(String)? onTapLink,
}) {
  return tester.pumpWidget(host(MarkdownView(data: data, style: style, streaming: streaming, onTapLink: onTapLink)));
}

/// The style of the leaf span holding [text] in the first matching paragraph.
TextStyle? styleOfText(WidgetTester tester, String text) {
  final paragraph = tester
      .renderObjectList<RenderParagraph>(find.byType(RichText))
      .firstWhere((p) => p.text.toPlainText().contains(text));
  TextStyle? found;
  void visit(InlineSpan span, TextStyle? inherited) {
    final effective = inherited?.merge(span.style) ?? span.style;
    if (span is TextSpan) {
      if (span.text != null && span.text!.contains(text)) found = effective;
      span.children?.forEach((c) => visit(c, effective));
    }
  }

  visit(paragraph.text, null);
  return found;
}

void main() {
  testWidgets('renders paragraphs with inline formatting', (tester) async {
    await pumpMarkdown(tester, 'Hello **bold** and *it* and `code`.');
    // Short inline code is a chip (a WidgetSpan), so it is its own Text.
    expect(find.text('Hello bold and it and ￼.'), findsOneWidget);
    expect(find.text('code'), findsOneWidget);
    expect(styleOfText(tester, 'bold')!.fontWeight, FontWeight.bold);
    expect(styleOfText(tester, 'it')!.fontStyle, FontStyle.italic);
    expect(styleOfText(tester, 'code')!.fontFamily, style.inlineCode.fontFamily);
  });

  testWidgets('renders headings with heading styles', (tester) async {
    await pumpMarkdown(tester, '# Big title\n\n### Small title\n\nBody');
    expect(find.text('Big title'), findsOneWidget);
    expect(find.text('Small title'), findsOneWidget);
    expect(find.text('Body'), findsOneWidget);
    expect(styleOfText(tester, 'Big title')!.fontSize, style.h1.fontSize);
    expect(styleOfText(tester, 'Small title')!.fontSize, style.h3.fontSize);
  });

  testWidgets('renders lists, task lists and blockquotes', (tester) async {
    await pumpMarkdown(
      tester,
      '- apple\n- banana\n  1. nested\n\n'
      '- [x] done\n- [ ] todo\n\n'
      '> quoted',
    );
    expect(find.text('apple'), findsOneWidget);
    expect(find.text('nested'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('☑'), findsOneWidget);
    expect(find.text('☐'), findsOneWidget);
    expect(find.text('quoted'), findsOneWidget);
  });

  testWidgets('code block shows language, copies and resets', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpMarkdown(tester, '```dart\nvoid main() => print(1);\n```');
    expect(find.byType(CodeBlockView), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('void main() => print(1);'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, <String>['void main() => print(1);']);
    expect(find.text('Copied'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('code is syntax highlighted', (tester) async {
    await pumpMarkdown(tester, '```python\ndef f():\n    return "s"\n```');
    final keyword = styleOfText(tester, 'def');
    expect(keyword?.color, style.syntaxTheme['keyword']!.color);
  });

  testWidgets('renders tables', (tester) async {
    await pumpMarkdown(tester, '| Name | Score |\n|:-----|------:|\n| Ada | 99 |\n| Linus | 7 |');
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Linus'), findsOneWidget);
    final score = tester.widget<Text>(find.text('99'));
    expect(score.textAlign, TextAlign.end);
    expect(find.ancestor(of: find.byType(Table), matching: find.byType(SingleChildScrollView)), findsOneWidget);
  });

  testWidgets('renders math through the math builder', (tester) async {
    await pumpMarkdown(tester, 'Inline \$x^2\$ here.\n\n\$\$\n\\frac{a}{b}\n\$\$');
    expect(find.byType(Math), findsNWidgets(2));
  });

  testWidgets('typst fences go through the code block builder', (tester) async {
    final seen = <String?>[];
    await tester.pumpWidget(
      host(
        MarkdownView(
          data: '```typst\n#set text(size: 11pt)\n```\n\n```math\nx\n```',
          style: style,
          codeBlockBuilder: (context, code, language) {
            seen.add(language);
            return Text('code:$code');
          },
          mathBuilder: (context, tex, {required display}) => Text('math:$tex:$display'),
        ),
      ),
    );
    expect(seen, <String?>['typst']);
    expect(find.text('code:#set text(size: 11pt)'), findsOneWidget);
    expect(find.text('math:x:true'), findsOneWidget);
  });

  testWidgets('invalid tex falls back to raw source', (tester) async {
    await pumpMarkdown(tester, r'Bad $\frac{a$ math');
    expect(find.text(r'\frac{a'), findsOneWidget);
  });

  testWidgets('horizontal rule, image placeholder and footnotes', (tester) async {
    await pumpMarkdown(tester, 'Above\n\n---\n\n![A diagram](diagram.png)\n\nText[^1].\n\n[^1]: Footnote body.');
    expect(find.text('A diagram'), findsOneWidget);
    expect(find.text('Footnote body.'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('Text[1].'), findsOneWidget);
  });

  testWidgets('remote images load only when tapped; data images render at once', (tester) async {
    await pumpMarkdown(tester, '![Chart](https://evil.example/p?q=secret)');
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Load from evil.example'), findsOneWidget);
    await tester.tap(find.textContaining('Load from evil.example'));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);

    await pumpMarkdown(
      tester,
      '![Dot](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==)',
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Load from'), findsNothing);
  });

  testWidgets('confirmRemoteImage decides whether a tapped image loads', (tester) async {
    const md = '![Chart](https://evil.example/p?q=secret)';
    final asked = <String>[];
    Future<void> pumpWith(bool answer) => tester.pumpWidget(
      host(
        MarkdownView(
          data: md,
          style: style,
          confirmRemoteImage: (src) async {
            asked.add(src);
            return answer;
          },
        ),
      ),
    );

    await pumpWith(false);
    await tester.tap(find.textContaining('Load from evil.example'));
    await tester.pump();
    expect(asked, ['https://evil.example/p?q=secret']);
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Load from evil.example'), findsOneWidget);

    await pumpWith(true);
    await tester.tap(find.textContaining('Load from evil.example'));
    await tester.pump();
    expect(asked, hasLength(2));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('tapping a link reports its href', (tester) async {
    final taps = <String>[];
    await pumpMarkdown(tester, '[Open docs](https://docs.dev)', onTapLink: taps.add);
    // The paragraph is full width; tap on the glyphs, then on empty space.
    final topLeft = tester.getTopLeft(find.text('Open docs'));
    await tester.tapAt(topLeft + const Offset(12, 10));
    expect(taps, <String>['https://docs.dev']);
    await tester.tapAt(topLeft + const Offset(500, 10));
    expect(taps, hasLength(1));
  });

  testWidgets('streaming renders unclosed constructs gracefully', (tester) async {
    const intro = 'Intro paragraph.\n\n';
    await pumpMarkdown(tester, '$intro```py\nprint(1)', streaming: true);
    expect(find.byType(CodeBlockView), findsOneWidget);
    expect(find.text('print(1)'), findsOneWidget);

    // An open ```math fence is a code block in progress, not broken math.
    await pumpMarkdown(tester, '$intro```math\n\\frac{1}{', streaming: true);
    expect(find.byType(CodeBlockView), findsOneWidget);
    expect(find.byType(Math), findsNothing);

    // Unclosed $$ is plain text until closed.
    await pumpMarkdown(tester, '$intro\$\$\na + ', streaming: true);
    expect(find.text('\$\$\na + '), findsOneWidget);
    await pumpMarkdown(tester, '$intro\$\$\na + b\n\$\$', streaming: true);
    expect(find.byType(Math), findsOneWidget);

    await pumpMarkdown(tester, '$intro\$\$\na + b\n\$\$', streaming: false);
    expect(find.byType(Math), findsOneWidget);
    expect(find.text('Intro paragraph.'), findsOneWidget);
  });

  testWidgets('streaming keeps earlier block widgets', (tester) async {
    const intro = 'First block.\n\n';
    await pumpMarkdown(tester, '${intro}Second', streaming: true);
    final before = tester.widget(find.text('First block.'));
    await pumpMarkdown(tester, '${intro}Second block grows', streaming: true);
    expect(identical(tester.widget(find.text('First block.')), before), isTrue);
    expect(find.text('Second block grows'), findsOneWidget);
  });

  testWidgets('works inside a WidgetsApp with a SelectableRegion', (tester) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFFFFFFFF),
        builder: (context, _) => Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (context) => SelectableRegion(
                selectionControls: emptyTextSelectionControls,
                child: MarkdownView(data: '## Hi\n\nSelectable text.', style: style),
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.text('Hi'), findsOneWidget);
    expect(find.text('Selectable text.'), findsOneWidget);
  });

  testWidgets('renders a mixed document without layout errors', (tester) async {
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: MarkdownView(
            data:
                '# Report\n\n'
                '> [!NOTE]\n> An alert with **bold**.\n\n'
                '> outer\n>> inner quote\n\n'
                '1. one\n2. two\n   - [x] sub task\n   - sub item with `code`\n\n'
                '| a | b | c |\n|---|:-:|--:|\n| x | y |\n\n'
                '    indented code\n\n'
                r'Inline \(a+b\) and \[c\] math.'
                '\n\n'
                '\\[\nx = 1\n\\]\n\n'
                'Line one  \nline two\n\n'
                '***\n\n'
                'Visit https://example.com or ~~not~~.',
            style: MarkdownStyle.fallback(Brightness.dark),
            selectable: false,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Report'), findsOneWidget);
    expect(find.text('inner quote'), findsOneWidget);
    expect(find.text('sub task'), findsOneWidget);
    expect(find.text('Line one\nline two'), findsOneWidget);
    expect(find.byType(SelectionContainer), findsWidgets);
    expect(find.byType(Math), findsNWidgets(3));
  });
}
