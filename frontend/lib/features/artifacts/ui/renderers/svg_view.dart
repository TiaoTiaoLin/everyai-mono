import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/every_theme.dart';

/// Removes what an inline illustration must not have: scripts, event
/// handlers, foreign HTML and references to outside resources. Links keep
/// only same-document fragments (`#id`) and inline raster images; CSS keeps
/// only `url(#id)`. SVGs are drawn natively (never in a webview), so this
/// guards what they could fetch, not script.
String sanitizeSvg(String svg) => svg
    .replaceAll(RegExp(r'<script[\s\S]*?</script\s*>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<script\b[^>]*/>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<foreignObject[\s\S]*?</foreignObject\s*>', caseSensitive: false), '')
    .replaceAll(RegExp(r'''\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''', caseSensitive: false), '')
    .replaceAllMapped(
      RegExp(r'''\s(xlink:)?href\s*=\s*("([^"]*)"|'([^']*)')''', caseSensitive: false),
      (m) => _safeRef(m[3] ?? m[4] ?? '') ? m[0]! : '',
    )
    .replaceAll(RegExp(r'@import[^;]*;?', caseSensitive: false), '')
    .replaceAllMapped(
      RegExp(r'''url\(\s*(["']?)([^)"']*)\1\s*\)''', caseSensitive: false),
      (m) => m[2]!.trim().startsWith('#') ? m[0]! : 'none',
    );

bool _safeRef(String ref) {
  final r = ref.trim().toLowerCase();
  return r.startsWith('#') || RegExp(r'^data:image/(png|jpe?g|gif|webp);').hasMatch(r);
}

/// `render_svg` and SVG artifacts.
class SvgView extends StatelessWidget {
  const SvgView({super.key, required this.svg, this.maxHeight = 420});

  final String svg;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          // Model SVGs usually assume a light page.
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(theme.radius),
          border: Border.all(color: theme.border),
        ),
        child: SvgPicture.string(
          sanitizeSvg(svg),
          fit: BoxFit.contain,
          errorBuilder: (context, error, _) =>
              Text('This illustration could not be drawn.', style: theme.type.body.tint(theme.textMuted)),
        ),
      ),
    );
  }
}
