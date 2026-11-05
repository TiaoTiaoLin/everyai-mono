import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:xml/xml.dart';

import '../../../../core/theme/every_theme.dart';

/// Keeps what an illustration may have: drawing elements from an allowlist,
/// links to `#id` fragments and inline raster images, and CSS whose `url()`
/// points at `#id`. Everything else goes: scripts, `foreignObject`, SMIL
/// animation (it can rewrite an href), event handlers, `src`/`srcset`, the
/// doctype (its entities could expand to markup), comments, `@import`, and CSS
/// with escapes or `image-set`. `title` and `desc` keep only their text: an
/// HTML parser reads markup inside them as HTML, and ends a comment at `--!>`
/// where XML doesn't. The tree is parsed, not matched with patterns, because
/// the result also reaches browsers and Markdown editors (downloads), which
/// run script and fetch. Invalid XML gives '' (flutter_svg can't draw it
/// either). Results are cached: a streaming answer rebuilds the same SVG on
/// every token.
String sanitizeSvg(String svg) {
  if (_cache.remove(svg) case final hit?) return _cache[svg] = hit;
  final clean = _sanitize(svg);
  _cache[svg] = clean;
  if (_cache.length > 16) _cache.remove(_cache.keys.first);
  return clean;
}

/// Most recently used last.
final _cache = <String, String>{};

String _sanitize(String svg) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(svg);
  } on XmlException {
    return '';
  }
  doc.children.removeWhere((n) => n is XmlDoctype || n is XmlProcessing || n is XmlComment);
  final root = doc.rootElement;
  if (root.name.local != 'svg') return '';
  _clean(root);
  return doc.toXmlString();
}

const _svgElements = {
  'svg', 'g', 'defs', 'use', 'symbol', 'marker', 'clippath', 'mask', 'pattern', 'lineargradient', 'radialgradient', //
  'stop', 'path', 'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon', 'text', 'tspan', 'textpath', 'title',
  'desc', 'image', 'a', 'style', 'filter',
};

bool _allowed(XmlElement e) {
  final name = e.name.local.toLowerCase();
  return _svgElements.contains(name) || name.startsWith('fe'); // filter primitives
}

void _clean(XmlElement e) {
  e.attributes.removeWhere((a) {
    final name = a.name.local.toLowerCase();
    if (name.startsWith('on') || name == 'base' || name == 'src' || name == 'srcset') return true;
    if (name == 'href') return !_safeRef(a.value);
    a.value = _css(a.value);
    return _outsideUrl.hasMatch(a.value);
  });
  final tag = e.name.local.toLowerCase();
  if (tag == 'style' || tag == 'title' || tag == 'desc') {
    final text = tag == 'style' ? _css(e.innerText) : e.innerText;
    e.children
      ..clear()
      ..add(XmlText(tag == 'style' && _outsideUrl.hasMatch(text) ? '' : text));
    return;
  }
  e.children.removeWhere((n) => n is XmlProcessing || n is XmlComment || (n is XmlElement && !_allowed(n)));
  // CDATA is text in XML but not inside HTML's integration points; plain text
  // is escaped the same way everywhere.
  for (final (i, n) in e.children.indexed.toList()) {
    if (n is XmlCDATA) e.children[i] = XmlText(n.value);
  }
  for (final child in e.childElements) {
    _clean(child);
  }
}

/// [css] without imports and with `url(…)` other than `url(#id)` as `none`.
/// What could still hide a fetch (escapes like `u\72l(`, `image-set("…")`, a
/// url the rewrite missed) is left for [_outsideUrl] to refuse.
String _css(String css) => css
    .replaceAll(RegExp(r'@import[^;]*;?', caseSensitive: false), '')
    .replaceAllMapped(
      RegExp(r'''url\(\s*(["']?)([^)"']*)\1\s*\)''', caseSensitive: false),
      (m) => m[2]!.trim().startsWith('#') ? m[0]! : 'none',
    );

final _outsideUrl = RegExp(r'''\\|image-set|url\(\s*(?!["']?\s*#)''', caseSensitive: false);

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
