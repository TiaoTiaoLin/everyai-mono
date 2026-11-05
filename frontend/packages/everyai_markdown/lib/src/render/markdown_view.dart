import 'package:flutter/widgets.dart';

import '../code/code_block_view.dart';
import '../parser/document.dart';
import '../style.dart';
import 'block_builder.dart';
import 'chips.dart';
import 'image.dart';
import 'math.dart';

/// Renders GitHub-flavored Markdown (plus math) with plain [Text.rich]
/// widgets, so it works inside an app-level `SelectionArea`.
///
/// Parsing is memoized: the document is re-parsed only when [data] changes.
/// While [streaming] is true and [data] grows by appending, only the last
/// top-level block is re-parsed (see [MarkdownDocument.appendParse]) and the
/// widgets of all earlier blocks are reused.
///
/// The view is not scrollable and expects a bounded width.
class MarkdownView extends StatefulWidget {
  const MarkdownView({
    super.key,
    required this.data,
    required this.style,
    this.streaming = false,
    this.mathBuilder,
    this.codeBlockBuilder,
    this.onTapLink,
    this.confirmRemoteImage,
    this.citationBuilder,
    this.onTapCitation,
    this.selectable = true,
    this.preserveSoftLineBreaks = false,
  });

  /// The Markdown source.
  final String data;

  final MarkdownStyle style;

  /// Whether [data] is still being streamed. Enables incremental parsing and
  /// tolerant rendering of unclosed fences and `$$` blocks.
  final bool streaming;

  /// Renders TeX. Defaults to [defaultMathBuilder] (flutter_math_fork).
  ///
  /// Prefer a stable function (top-level or static) so unchanged blocks can
  /// skip rebuilding.
  final MathBuilder? mathBuilder;

  /// Renders code blocks. Defaults to [defaultCodeBlockBuilder], i.e.
  /// [CodeBlockView]. Prefer a stable function, as for [mathBuilder].
  final CodeBlockBuilder? codeBlockBuilder;

  /// Called with the raw `href` when a link is tapped.
  final void Function(String href)? onTapLink;

  /// Asked with the image URL when the user taps a remote image to load it;
  /// false keeps it unloaded. Null loads on the tap.
  final Future<bool> Function(String src)? confirmRemoteImage;

  /// Renders citation markers (`[1]`, `[2][3]`) as emitted by search-backed
  /// models. Defaults to [defaultCitationBuilder], a small accent chip.
  /// Prefer a stable function, as for [mathBuilder].
  final CitationBuilder? citationBuilder;

  /// Called with the citation number when a citation chip is tapped.
  final void Function(int index)? onTapCitation;

  /// Whether the text participates in an enclosing `SelectionArea`.
  final bool selectable;

  /// Render soft line breaks (a single newline inside a paragraph) as line
  /// breaks rather than spaces. CommonMark renders them as spaces.
  final bool preserveSoftLineBreaks;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  late MarkdownDocument _document;

  @override
  void initState() {
    super.initState();
    _document = MarkdownDocument.parse(widget.data);
  }

  @override
  void didUpdateWidget(MarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != _document.source) {
      _document = widget.streaming
          ? MarkdownDocument.appendParse(_document, widget.data)
          : MarkdownDocument.parse(widget.data);
    } else if (!widget.streaming && _document.isIncremental) {
      // Streaming finished: one full parse resolves references that point
      // forward across blocks (link definitions, footnotes).
      _document = MarkdownDocument.parse(widget.data);
    }
  }

  void _handleTapLink(String href) => widget.onTapLink?.call(href);

  void _handleTapCitation(int index) => widget.onTapCitation?.call(index);

  Future<bool> _confirmImage(String src) => widget.confirmRemoteImage?.call(src) ?? Future.value(true);

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final config = RenderConfig(
      style: style,
      mathBuilder: widget.mathBuilder ?? defaultMathBuilder,
      codeBlockBuilder: widget.codeBlockBuilder ?? defaultCodeBlockBuilder,
      linksEnabled: widget.onTapLink != null,
      preserveSoftBreaks: widget.preserveSoftLineBreaks,
      citationBuilder: widget.citationBuilder ?? defaultCitationBuilder,
      citationsEnabled: widget.onTapCitation != null,
    );

    final children = <Widget>[];
    var previousHeading = -1;
    for (final block in _document.blocks) {
      final nodes = block.nodes.where((n) => !MarkdownDocument.isFootnoteDefinition(n)).toList(growable: false);
      if (nodes.isEmpty) continue;
      final firstHeading = BlockBuilder.headingLevel(nodes.first);
      final gap = previousHeading < 0
          ? 0.0
          : BlockBuilder.gapBetween(previousHeading, firstHeading, style.blockSpacing);
      previousHeading = BlockBuilder.headingLevel(nodes.last);
      children.add(
        Padding(
          key: ValueKey<int>(block.start),
          padding: EdgeInsets.only(top: gap),
          child: _BlockView(block: block, config: config, onTapLink: _handleTapLink, onTapCitation: _handleTapCitation),
        ),
      );
    }
    if (_document.footnotes.isNotEmpty) {
      children.add(
        Padding(
          padding: EdgeInsets.only(top: children.isEmpty ? 0 : style.blockSpacing),
          child: _FootnotesView(
            document: _document,
            config: config,
            onTapLink: _handleTapLink,
            onTapCitation: _handleTapCitation,
          ),
        ),
      );
    }

    Widget result = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    result = DefaultSelectionStyle.merge(
      selectionColor: style.selection,
      child: DefaultTextStyle.merge(style: style.body, child: result),
    );
    if (!widget.selectable) {
      result = SelectionContainer.disabled(child: result);
    }
    return MarkdownStyleScope(
      style: style,
      child: RemoteImageGate(confirm: _confirmImage, child: result),
    );
  }
}

/// Renders one [MarkdownBlock], caching the built subtree while the block
/// object and render configuration stay the same. During streaming this makes
/// every block but the last one free to rebuild.
class _BlockView extends StatefulWidget {
  const _BlockView({required this.block, required this.config, required this.onTapLink, required this.onTapCitation});

  final MarkdownBlock block;
  final RenderConfig config;
  final ValueChanged<String> onTapLink;
  final ValueChanged<int> onTapCitation;

  @override
  State<_BlockView> createState() => _BlockViewState();
}

class _BlockViewState extends State<_BlockView> {
  Widget? _cached;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cached = null;
  }

  @override
  void didUpdateWidget(_BlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.block, widget.block) || oldWidget.config != widget.config) {
      _cached = null;
    }
  }

  void _handleTapLink(String href) => widget.onTapLink(href);

  void _handleTapCitation(int index) => widget.onTapCitation(index);

  @override
  Widget build(BuildContext context) {
    return _cached ??= BlockBuilder(
      context: context,
      config: widget.config,
      onTapLink: _handleTapLink,
      onTapCitation: _handleTapCitation,
      openCodeBlock: widget.block.isOpen ? BlockBuilder.lastCodeBlock(widget.block.nodes) : null,
    ).build(widget.block.nodes);
  }
}

class _FootnotesView extends StatelessWidget {
  const _FootnotesView({
    required this.document,
    required this.config,
    required this.onTapLink,
    required this.onTapCitation,
  });

  final MarkdownDocument document;
  final RenderConfig config;
  final ValueChanged<String> onTapLink;
  final ValueChanged<int> onTapCitation;

  @override
  Widget build(BuildContext context) {
    return BlockBuilder(
      context: context,
      config: config,
      onTapLink: onTapLink,
      onTapCitation: onTapCitation,
    ).buildFootnotes(document.footnotes);
  }
}
