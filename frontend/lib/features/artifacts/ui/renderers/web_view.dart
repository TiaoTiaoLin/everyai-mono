import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../../chat/ui/link_gate.dart';
import '../../checks/web_scripts.dart';
import 'drawing_page.dart';
import 'sandbox.dart';

export 'sandbox.dart' show WebSurface;

/// Whether this platform can show web content inline (Linux has no webview).
bool get inlineWebSupported =>
    kIsWeb ||
    switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.iOS || TargetPlatform.android => true,
      _ => false,
    };

/// A page that draws Mermaid source with the bundled Mermaid (the marker is
/// swapped for it by [withBundledScripts]), so diagrams work offline.
String mermaidPage(String source, {required bool dark}) =>
    '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;background:transparent;display:flex;justify-content:center}
.mermaid{font-family:-apple-system,system-ui,sans-serif}</style></head>
<body><pre class="mermaid">${const HtmlEscape().convert(source)}</pre>
$mermaidScriptMarker
<script>mermaid.initialize({startOnLoad:true,theme:"${dark ? 'dark' : 'default'}",securityLevel:"strict"});</script>
</body></html>''';

/// HTML in an embedded webview, inside a sandboxed iframe with a CSP (see
/// `sandbox.dart`); elsewhere, the source with "Open in browser". Bundled
/// scripts the page asks for ([mermaidScriptMarker]) are inlined first.
///
/// A [WebSurface.widget] with no [height] sizes itself to its content, and
/// its `window.everyai.send(text)` calls [onSend]. A [WebSurface.drawing]
/// reports the edited scene to [onScene].
class WebContentView extends StatefulWidget {
  const WebContentView({
    super.key,
    required this.html,
    required this.fallbackSource,
    this.height = 360,
    this.surface = WebSurface.page,
    this.interactive = true,
    this.onSend,
    this.onScene,
  });

  final String html;

  /// Shown where there is no webview (Linux), e.g. the Mermaid source.
  final String fallbackSource;
  final double? height;
  final WebSurface surface;

  /// False shows the page without running any script.
  final bool interactive;
  final ValueChanged<String>? onSend;
  final ValueChanged<String>? onScene;

  @override
  State<WebContentView> createState() => _WebContentViewState();
}

class _WebContentViewState extends State<WebContentView> {
  late Future<String> _doc = withBundledScripts(widget.html);
  final _token = _randomToken();
  double _contentHeight = 120;
  DateTime _lastSend = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void didUpdateWidget(WebContentView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _doc = withBundledScripts(widget.html);
  }

  (Object, String)? _page;

  /// The host page, rebuilt only when its inputs change (Mermaid pages are
  /// megabytes).
  String _pageFor(String doc, String css) {
    final key = Object.hash(doc, css, widget.surface, widget.interactive);
    if (_page case (final k, final page) when k == key) return page;
    final page = sandboxedHostPage(
      doc,
      surface: widget.surface,
      interactive: widget.interactive,
      theme: css,
      token: _token,
    );
    _page = (key, page);
    return page;
  }

  void _send(String text) {
    final now = DateTime.now();
    if (now.difference(_lastSend) < const Duration(seconds: 2)) return; // no floods
    _lastSend = now;
    widget.onSend?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (!inlineWebSupported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChatMarkdown('```\n${widget.fallbackSource}\n```'),
          GestureDetector(
            onTap: () => openHtmlInBrowser(widget.html, surface: widget.surface),
            child: Text('Open in browser', style: theme.type.callout.medium.tint(theme.accent)),
          ),
        ],
      );
    }
    final css = themeCss(theme);
    final autoSize = widget.surface == WebSurface.widget && widget.height == null;
    final view = ClipRRect(
      borderRadius: BorderRadius.circular(theme.radius),
      child: FutureBuilder<String>(
        future: _doc,
        builder: (context, snap) {
          final doc = snap.data;
          if (doc == null) return const SizedBox.shrink();
          final page = _pageFor(doc, css);
          return InAppWebView(
            key: ValueKey(page.hashCode),
            initialData: InAppWebViewInitialData(data: page, baseUrl: WebUri('about:blank')),
            initialSettings: InAppWebViewSettings(
              transparentBackground: true,
              javaScriptEnabled: true,
              supportZoom: false,
              disableContextMenu: false,
              useShouldOverrideUrlLoading: true,
              javaScriptCanOpenWindowsAutomatically: false,
              supportMultipleWindows: false,
            ),
            onWebViewCreated: (controller) {
              controller.addJavaScriptHandler(
                handlerName: sendHandler,
                callback: (args) {
                  final text = acceptWidgetMessage(acceptHandlerCall(args, _token));
                  if (text != null && mounted) _send(text);
                  return null;
                },
              );
              controller.addJavaScriptHandler(
                handlerName: sceneHandler,
                callback: (args) {
                  final scene = acceptHandlerCall(args, _token);
                  if (scene is String && scene.length <= maxSceneLength && mounted) widget.onScene?.call(scene);
                  return null;
                },
              );
              controller.addJavaScriptHandler(
                handlerName: heightHandler,
                callback: (args) {
                  final h = acceptHandlerCall(args, _token);
                  if (autoSize && h is num && mounted) {
                    final next = h.toDouble().clamp(40.0, 900.0);
                    if ((next - _contentHeight).abs() >= 1) setState(() => _contentHeight = next);
                  }
                  return null;
                },
              );
            },
            shouldOverrideUrlLoading: (controller, action) async => navigationPolicy(
              action.request.url,
              userClicked: action.hasGesture == true || action.navigationType == NavigationType.LINK_ACTIVATED,
              open: (url) => openOutside(context, url),
            ),
          );
        },
      ),
    );
    final height = autoSize ? _contentHeight : widget.height;
    return height == null ? view : SizedBox(height: height, child: view);
  }
}

/// Where a sandboxed page may navigate: only to its own srcdoc and blank
/// frames. A link the user clicked opens in the browser; anything else
/// (script redirects, file and data URLs) is cancelled.
Future<NavigationActionPolicy> navigationPolicy(
  Uri? url, {
  required bool userClicked,
  required Future<Object?> Function(Uri url) open,
}) async {
  if (url == null) return NavigationActionPolicy.CANCEL;
  if (url.scheme == 'about') return NavigationActionPolicy.ALLOW;
  if ((url.scheme == 'http' || url.scheme == 'https') && userClicked) await open(url);
  return NavigationActionPolicy.CANCEL;
}

String _randomToken() {
  final r = Random.secure();
  return List.generate(24, (_) => r.nextInt(36).toRadixString(36)).join();
}

/// Writes [html] to a temporary file and opens it in the default browser.
/// The page stays in its sandbox there too (static for web pages opened from
/// a static panel, see [interactive]).
Future<void> openHtmlInBrowser(String html, {WebSurface surface = WebSurface.page, bool interactive = true}) async {
  if (kIsWeb) return;
  html = sandboxedHostPage(await withBundledScripts(html), surface: surface, interactive: interactive);
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/everyai-${html.hashCode.toUnsigned(32)}.html');
  await file.writeAsString(html);
  await launchUrl(Uri.file(file.path));
}
