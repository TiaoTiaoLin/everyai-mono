import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import '../checks/math_raster.dart';
import '../checks/web_scripts.dart';
import '../checks/webview_diagram_renderer.dart';
import '../domain/artifact.dart';
import '../domain/chart_spec.dart';
import '../ui/renderers/sandbox.dart';
import '../ui/renderers/slides_view.dart';
import '../ui/renderers/svg_view.dart';
import 'chart_svg.dart';
import 'diagram_raster.dart';
import 'doc_model.dart';
import 'docx_writer.dart';
import 'pdf_writer.dart';
import 'pptx_writer.dart';
import 'svg_raster.dart';

/// One way to download a visual: a label, a file extension and the bytes.
final class DownloadOption {
  const DownloadOption(this.label, this.extension, this.build);
  final String label;
  final String extension;
  final Future<Uint8List> Function() build;
}

/// What a visual can be saved as, the most useful first. Documents (and
/// quizzes) get Markdown, PDF and Word, plus a zip with separate figure files
/// when they hold SVG figures.
List<DownloadOption> downloadsOf(Visual v) {
  final export = exportOf(v);
  Future<Uint8List> utf8Of(String text) async => Uint8List.fromList(utf8.encode(text));
  switch (v.kind) {
    case VisualKind.document || VisualKind.quiz:
      final markdown = export.text;
      return [
        DownloadOption('Markdown', 'md', () => utf8Of(markdownWithInlineSvg(markdown))),
        if (svgFiguresIn(markdown).isNotEmpty)
          DownloadOption('Markdown with figure files', 'zip', () async => markdownZip(markdown, export.name)),
        DownloadOption('PDF', 'pdf', () => pdfOf(v.title, markdown)),
        DownloadOption('Word', 'docx', () => docxOf(v.title, markdown)),
      ];
    case VisualKind.slides:
      return [
        DownloadOption('PowerPoint', 'pptx', () async => pptxOf(v)),
        DownloadOption('Markdown', 'md', () => utf8Of(export.text)),
      ];
    case VisualKind.image:
      final bytes = v.args['bytes'];
      return [
        DownloadOption(export.extension.toUpperCase(), export.extension, () async {
          if (bytes is! Uint8List) throw StateError('This image is no longer stored.');
          return bytes;
        }),
      ];
    case VisualKind.html || VisualKind.widget:
      // Saved inside the same sandbox and policy as on screen: opened from
      // disk, raw model markup would run with no limits. Copy keeps the source.
      final surface = v.kind == VisualKind.widget ? WebSurface.widget : WebSurface.page;
      return [
        DownloadOption('Web page', 'html', () async {
          final page = await withBundledScripts(export.text);
          return utf8Of(sandboxedHostPage(page, surface: surface, interactive: true));
        }),
      ];
    case VisualKind.svg:
      return [
        DownloadOption('SVG', 'svg', () => utf8Of(sanitizeSvg(export.text))),
        DownloadOption('PNG', 'png', () async {
          final f = await rasterizeSvg(export.text, maxWidth: 1600, scale: 2);
          if (f == null) throw StateError('This illustration could not be drawn.');
          return f.png;
        }),
      ];
    case VisualKind.chart:
      final spec = ChartSpec.fromJson(v.args);
      final svg = chartSvg(spec);
      return [
        if (svg != null) ...[
          DownloadOption('PNG', 'png', () async {
            final f = await rasterizeSvg(svg, maxWidth: 1600, scale: 2);
            if (f == null) throw StateError('This chart could not be drawn.');
            return f.png;
          }),
          DownloadOption('SVG', 'svg', () => utf8Of(svg)),
        ],
        DownloadOption('CSV', 'csv', () => utf8Of(spec.csv)),
        DownloadOption('JSON', 'json', () => utf8Of(export.text)),
      ];
    case VisualKind.diagram when diagramChecksSupported:
      return [
        DownloadOption('PNG', 'png', () async {
          final f = await (await drawnDiagram(export.text)).figure(maxWidth: double.infinity);
          if (f == null) throw StateError('This diagram could not be drawn.');
          return f.png;
        }),
        DownloadOption('SVG', 'svg', () async => utf8Of((await drawnDiagram(export.text)).svg)),
        DownloadOption('Mermaid', 'mmd', () => utf8Of(export.text)),
      ];
    default:
      return [DownloadOption(export.extension.toUpperCase(), export.extension, () => utf8Of(export.text))];
  }
}

/// [markdown] with each ```svg block written as inline `<svg>` HTML, which
/// VS Code, Obsidian, Typora and most Markdown editors draw in place.
/// Figures are sanitized as on screen, since those editors run their script.
String markdownWithInlineSvg(String markdown) => _replaceSvgFences(
  markdown,
  (svg, _) => '\n${sanitizeSvg(svg).split('\n').where((l) => l.trim().isNotEmpty).join('\n')}\n',
);

/// A zip of the Markdown with figures as `figures/figure-N.svg` files linked
/// as images, the form GitHub and every viewer render.
Uint8List markdownZip(String markdown, String name) {
  final archive = Archive();
  void add(String path, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  final text = _replaceSvgFences(markdown, (svg, n) {
    add('$name/figures/figure-$n.svg', sanitizeSvg(svg));
    return '![Figure $n](figures/figure-$n.svg)';
  });
  add('$name/$name.md', text);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _replaceSvgFences(String markdown, String Function(String svg, int n) replace) {
  final lines = fenceRawSvg(markdown).split('\n');
  final out = <String>[];
  var n = 0;
  for (var i = 0; i < lines.length; i++) {
    final open = RegExp(r'^\s*(`{3,}|~{3,})\s*svg\s*$', caseSensitive: false).firstMatch(lines[i]);
    if (open != null) {
      final end = lines.indexWhere((l) => l.trim().startsWith(open[1]!), i + 1);
      if (end > 0) {
        final svg = lines.sublist(i + 1, end).join('\n');
        if (svg.contains('</svg>')) {
          out.add(replace(svg, ++n));
          i = end;
          continue;
        }
      }
    }
    out.add(lines[i]);
  }
  return out.join('\n');
}

Future<PdfFonts> _pdfFonts() async => (
  regular: await rootBundle.load('assets/fonts/NotoSans/NotoSans-Regular.ttf'),
  bold: await rootBundle.load('assets/fonts/NotoSans/NotoSans-Bold.ttf'),
  italic: await rootBundle.load('assets/fonts/NotoSans/NotoSans-Italic.ttf'),
  boldItalic: await rootBundle.load('assets/fonts/NotoSans/NotoSans-BoldItalic.ttf'),
  mono: await rootBundle.load('assets/fonts/SourceCodePro/SourceCodePro-Regular.ttf'),
);

/// [markdown] as a PDF, figures drawn as the app draws them; Mermaid and
/// display math as images where they can be drawn.
Future<Uint8List> pdfOf(
  String title,
  String markdown, {
  SvgRasterizer rasterize = rasterizeSvg,
  DiagramRasterizer drawDiagram = rasterizeDiagram,
  MathRasterizer drawMath = rasterizeTex,
}) async {
  final images = await _documentImages(markdown, rasterize, drawDiagram, drawMath);
  return buildPdf(
    title: title,
    blocks: parseDoc(markdown),
    fonts: await _pdfFonts(),
    figures: images.figures,
    diagrams: images.diagrams,
    equations: images.equations,
  );
}

/// [markdown] as a Word document, with images like [pdfOf].
Future<Uint8List> docxOf(
  String title,
  String markdown, {
  SvgRasterizer rasterize = rasterizeSvg,
  DiagramRasterizer drawDiagram = rasterizeDiagram,
  MathRasterizer drawMath = rasterizeTex,
}) async {
  final images = await _documentImages(markdown, rasterize, drawDiagram, drawMath);
  return buildDocx(
    title: title,
    blocks: parseDoc(markdown),
    figures: images.figures,
    diagrams: images.diagrams,
    equations: images.equations,
  );
}

Future<({Map<String, RasterFigure> figures, Map<String, RasterFigure> diagrams, Map<String, RasterFigure> equations})>
_documentImages(String markdown, SvgRasterizer svg, DiagramRasterizer diagram, MathRasterizer math) async => (
  figures: await rasterizeAll(svgFiguresIn(markdown), svg),
  diagrams: await rasterizeAll(diagramSourcesIn(markdown), diagram),
  equations: await rasterizeAll(displayMathIn(markdown), math),
);

/// The deck in [v] as a PowerPoint file.
Uint8List pptxOf(Visual v) {
  final deck = DeckTheme.of(v.str('theme'));
  String hex(Color c) => (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  final slides = slidesOf(v);
  return buildPptx(
    title: v.title,
    colors: (background: hex(deck.background), title: hex(deck.title), text: hex(deck.text), accent: hex(deck.accent)),
    slides: [
      for (final (i, s) in slides.indexed)
        (title: s.title, bullets: s.bullets, body: s.body, notes: s.notes, isTitle: i == 0),
    ],
  );
}

/// What Copy produces for a visual (and the plain download).
({String text, String name, String extension}) exportOf(Visual v) {
  final name = v.title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim().replaceAll(' ', '-').toLowerCase();
  final safe = name.isEmpty ? 'artifact' : name;
  return switch (v.kind) {
    VisualKind.document => (text: v.str('content'), name: safe, extension: 'md'),
    VisualKind.code => (text: v.str('content'), name: safe, extension: _extensionFor(v.str('language'))),
    VisualKind.html => (text: v.str('content'), name: safe, extension: 'html'),
    VisualKind.widget => (text: v.str('html'), name: safe, extension: 'html'),
    VisualKind.svg => (text: v.args['svg'] as String? ?? v.str('content'), name: safe, extension: 'svg'),
    VisualKind.diagram => (text: v.args['mermaid'] as String? ?? v.str('content'), name: safe, extension: 'mmd'),
    VisualKind.chart => (text: const JsonEncoder.withIndent('  ').convert(v.args), name: safe, extension: 'json'),
    VisualKind.quiz => (text: _quizMarkdown(v), name: safe, extension: 'md'),
    VisualKind.flashcards => (
      text: [
        for (final c in (v.args['cards'] as List<Object?>?) ?? const [])
          if (c case {'front': final String f, 'back': final String b}) '$f\t$b',
      ].join('\n'),
      name: safe,
      extension: 'tsv',
    ),
    VisualKind.image => (text: v.str('prompt'), name: safe, extension: imageExtension(v.str('mime'))),
    VisualKind.drawing => (text: v.str('content'), name: safe, extension: 'excalidraw'),
    VisualKind.slides => (
      text: [
        for (final s in slidesOf(v))
          ['# ${s.title}', for (final b in s.bullets) '- $b', if (s.body.isNotEmpty) s.body].join('\n'),
      ].join('\n\n---\n\n'),
      name: safe,
      extension: 'md',
    ),
  };
}

/// `image/jpeg` → `jpg`, and so on; png when unknown.
String imageExtension(String mime) => switch (mime) {
  'image/jpeg' || 'image/jpg' => 'jpg',
  'image/webp' => 'webp',
  'image/gif' => 'gif',
  'image/svg+xml' => 'svg',
  _ => 'png',
};

String _quizMarkdown(Visual v) {
  final b = StringBuffer('# ${v.title}\n');
  for (final (i, q) in ((v.args['questions'] as List<Object?>?) ?? const []).indexed) {
    if (q is! Map) continue;
    b.write('\n${i + 1}. ${q['question']}\n');
    for (final (oi, o) in ((q['options'] as List<Object?>?) ?? const []).indexed) {
      b.write('   ${String.fromCharCode(65 + oi)}. $o\n');
    }
  }
  return b.toString();
}

String _extensionFor(String language) => switch (language.toLowerCase()) {
  'python' || 'py' => 'py',
  'javascript' || 'js' => 'js',
  'typescript' || 'ts' => 'ts',
  'dart' => 'dart',
  'zig' => 'zig',
  'rust' || 'rs' => 'rs',
  'go' => 'go',
  'java' => 'java',
  'kotlin' => 'kt',
  'swift' => 'swift',
  'c' => 'c',
  'cpp' || 'c++' => 'cpp',
  'csharp' || 'c#' => 'cs',
  'ruby' => 'rb',
  'php' => 'php',
  'html' => 'html',
  'css' => 'css',
  'sql' => 'sql',
  'shell' || 'bash' || 'sh' => 'sh',
  'json' => 'json',
  'yaml' || 'yml' => 'yaml',
  _ => 'txt',
};
