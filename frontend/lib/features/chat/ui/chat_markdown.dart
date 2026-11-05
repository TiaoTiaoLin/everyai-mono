import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../artifacts/domain/chart_spec.dart';
import '../../artifacts/ui/renderers/chart_view.dart';
import '../../artifacts/ui/renderers/svg_view.dart';
import '../../artifacts/ui/renderers/web_view.dart';
import '../domain/message.dart';
import 'link_gate.dart';

/// Markdown for chat content, styled from the app tokens so it matches every
/// design language. The only place the app touches the renderer package.
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown(this.data, {super.key, this.streaming = false, this.textColor, this.sources = const []});

  final String data;
  final bool streaming;

  /// Sources the `[n]` citations in [data] point at (search modes).
  final List<Source> sources;

  /// Overrides the body color (user bubbles sit on the accent-tinted fill).
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MarkdownView(
      data: data,
      streaming: streaming,
      style: _styleFor(theme, DefaultTextStyle.of(context).style, textColor),
      codeBlockBuilder: _figures,
      onTapCitation: sources.isEmpty
          ? null
          : (index) {
              if (index >= 1 && index <= sources.length) {
                openOutside(context, sources[index - 1].url);
              }
            },
      onTapLink: (href) {
        final uri = Uri.tryParse(href);
        if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme == 'mailto')) {
          openOutside(context, uri);
        }
      },
      // Remote images already wait for a tap; one whose address carries data asks first.
      confirmRemoteImage: (src) => confirmRemote(context, Uri.parse(src)),
    );
  }

  /// ```svg blocks draw as figures, ```chart blocks as charts and ```mermaid blocks as diagrams, once
  /// complete; anything else (or a block still streaming) is code.
  static Widget _figures(BuildContext context, String text, String? language) {
    switch (language?.toLowerCase()) {
      case 'svg' when text.contains('</svg>'):
        return SvgView(svg: text, maxHeight: 560);
      case 'chart':
        if (ChartSpec.tryParse(text) case final spec?) return ChartView(spec: spec, showTitle: true);
      case 'mermaid' when text.trim().isNotEmpty && inlineWebSupported:
        final dark = EveryTheme.of(context).brightness == Brightness.dark;
        return WebContentView(
          html: mermaidPage(text, dark: dark),
          fallbackSource: text,
          height: 340,
        );
    }
    return defaultCodeBlockBuilder(context, text, language);
  }

  static MarkdownStyle _styleFor(EveryTheme t, TextStyle ambient, Color? textColor) {
    final base = MarkdownStyle.fallback(t.brightness);
    // Reading text is the scale's body; on desktop one point up, since answers are long-form.
    final size = t.type.body.fontSize! + (Host.isDesktop ? 1 : 0);
    final body = ambient.merge(t.type.body).copyWith(color: textColor ?? t.text, fontSize: size, height: 1.55);
    TextStyle heading(double scale) => body.semibold.copyWith(fontSize: size * scale, height: 1.3);
    final mono = body.mono.copyWith(fontSize: size - 1.5, height: 1.5);
    return base.copyWith(
      body: body,
      h1: heading(1.6),
      h2: heading(1.33),
      h3: heading(1.13),
      h4: heading(1),
      h5: heading(0.93),
      h6: heading(0.87),
      // Text color comes from the package's chip palette (warm on dark, plum on light).
      inlineCode: base.inlineCode.mono.copyWith(fontSize: size - 2),
      codeBlock: mono,
      blockquote: body.copyWith(color: t.textMuted),
      // Underline on hover only (handled by the renderer).
      link: body.copyWith(color: t.accent, decorationColor: t.accent),
      codeBlockBackground: t.codeBackground,
      citationBackground: t.accent.withValues(alpha: 0.18),
      citationText: t.text,
      codeBlockBorder: t.border,
      blockquoteBar: t.accent.withValues(alpha: 0.6),
      tableBorder: t.border,
      ruleColor: t.border,
      codeBlockRadius: t.radius,
    );
  }
}
