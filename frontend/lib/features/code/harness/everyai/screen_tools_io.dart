// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../../../core/security/official_sites.dart';
import '../../../../core/security/untrusted.dart';
import 'browser_io.dart';
import 'exfil.dart';
import 'tools_io.dart' show ToolOutput, imageDataUrl;
import 'window_capture_io.dart';

// The browser and screenshot tools' work, shared by the EveryAI harness's
// own tools and the app's MCP host (outside agents).

/// Runs one browser tool call ([args] as the `browser` spec has them) on [b].
/// Screenshots go under [root]'s `.everyai/scratch/screenshots/`; [fit] cuts
/// a long eval result (text, a name for its spill file).
Future<ToolOutput> runBrowser(
  HeadlessBrowser b,
  Map<String, Object?> args, {
  required String root,
  required bool vision,
  required String Function(String text, String name) fit,
}) async {
  final action = args['action'] as String? ?? '';
  String? str(String k) => (args[k] as String?)?.trim().isEmpty ?? true ? null : (args[k] as String).trim();
  double? at(String k) => (args[k] as num?)?.toDouble();
  var shot = args['screenshot'] == true;
  // Our own line about the site (a bare IP, a shortener, ...), kept outside the page's untrusted block.
  String? note;
  try {
    final String did;
    switch (action) {
      case 'open':
        final url = str('url');
        if (url == null) return const ToolOutput('Error: open needs a url.', isError: true);
        // A bare path or localhost:port is what agents often pass.
        final target = url.startsWith('/')
            ? Uri.file(url).toString()
            : RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(url) && !url.startsWith('localhost:')
            ? url
            : 'http://$url';
        if (_openRefusal(target) case final refusal?) return ToolOutput(refusal, isError: true);
        final before = browserTarget(target);
        if (before.refusal case final refusal?) return ToolOutput(refusal, isError: true);
        final opened = await b.open(target);
        // Chrome follows redirects itself: judge where it landed too.
        final landed = await b.evaluate('location.href');
        final after = landed is String ? browserLanded(target, landed) : _clear;
        if (after.refusal case final refusal?) {
          await b.open('about:blank');
          final where = 'The page redirected to another site, so the browser went back to a blank page.';
          return ToolOutput('$where\n$refusal', isError: true);
        }
        note = [before.notice, after.notice].nonNulls.join('\n');
        did = 'Opened $opened';
      case 'click':
        final sel = str('selector');
        if (sel == null && (at('x') == null || at('y') == null)) {
          return const ToolOutput('Error: click needs a selector, or x and y.', isError: true);
        }
        did = await b.click(selector: sel, x: at('x'), y: at('y'), count: (args['count'] as num?)?.toInt() ?? 1);
      case 'type':
        final text = args['text'] as String?;
        if (text == null) return const ToolOutput('Error: type needs text.', isError: true);
        did = await b.type(text, selector: str('selector'), submit: args['submit'] == true);
      case 'press':
        did = await b.press(str('key') ?? 'Enter');
      case 'scroll':
        did = await b.scroll(at('dy') ?? 600, x: at('x'), y: at('y'));
      case 'wait':
        did = await b.wait(selector: str('selector'), ms: (args['ms'] as num?)?.toInt() ?? 5000);
      case 'eval':
        final script = args['script'] as String?;
        if (script == null || script.trim().isEmpty) {
          return const ToolOutput('Error: eval needs a script.', isError: true);
        }
        did = 'Result: ${fit(const JsonEncoder.withIndent('  ').convert(await b.evaluate(script)), 'browser-eval')}';
      case 'screenshot':
        shot = true;
        did = 'Screenshot of ${await b.describe()}';
      case 'console':
        did = 'Console since the last read:';
      case 'resize':
        did = await b.resize((args['width'] as num?)?.toInt() ?? 1280, (args['height'] as num?)?.toInt() ?? 800);
      case 'close':
        await b.close();
        return const ToolOutput('Closed the browser.');
      default:
        return ToolOutput('Error: unknown browser action "$action".', isError: true);
    }
    final page = browserResultText(action, did, b.takeLog());
    final text = note == null || note.isEmpty ? page : '$note\n$page';
    if (!shot) return ToolOutput(text);
    final png = await b.screenshot(fullPage: args['full_page'] == true);
    final dir = Directory('$root/.everyai/scratch/screenshots')..createSync(recursive: true);
    final path = '${dir.path}/browser-${DateTime.now().millisecondsSinceEpoch}.png';
    File(path).writeAsBytesSync(png);
    final url = await _pngDataUrl(png);
    if (!vision || url == null) {
      return ToolOutput('$text\nSaved the screenshot to $path (this model can\'t view images).');
    }
    return ToolOutput('$text\nScreenshot: $path', images: [(label: path, dataUrl: url)]);
  } on BrowserError catch (e) {
    return ToolOutput(browserErrorText(action, e.message, b.takeLog()), isError: true);
  }
}

/// Why the browser may not open [target]: a file in one of the user's credential stores (the browser would show
/// it), or a site that takes uploads. Checked here, so the outside leads' host browser has the same guard.
String? _openRefusal(String target) {
  final uri = Uri.tryParse(target);
  if (uri == null) return null;
  if (uri.isScheme('file')) {
    var path = uri.toFilePath();
    try {
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
        path = File(path).resolveSymbolicLinksSync();
      }
    } on FileSystemException {
      // Checked as written.
    }
    final what = credentialPath(path, home: Platform.environment['HOME'] ?? '');
    return what == null ? null : guardRefusal('the file holds $what');
  }
  final site = exfilHost(uri.host);
  return site == null ? null : guardRefusal('$site is a site that takes uploads');
}

const _clear = (refusal: null, notice: null);

/// What the browser tool makes of [target] (before opening it, and again where a redirect landed): the refusal
/// for a look-alike of an official site, a one-line note for a host with a reason for doubt (a bare IP address, a
/// link shortener, `github.co`), or neither. The agent's own apps are never judged: files, localhost, private
/// addresses and `.local` names. Checked here, so the outside leads' host browser has the same guard.
({String? refusal, String? notice}) browserTarget(String target) {
  final uri = Uri.tryParse(target);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || _localHost(uri.host)) return _clear;
  final v = judgeHost(uri.host);
  final shown = _shownHost(uri.host);
  return switch (v.verdict) {
    SiteVerdict.ok => _clear,
    SiteVerdict.warn => (refusal: null, notice: siteNotice(shown, v)),
    SiteVerdict.refuse => (refusal: guardRefusal(siteRefusal(shown, v)), notice: null),
  };
}

/// [browserTarget] for the page Chrome [landed] on after opening [target], when a redirect took it to another host.
({String? refusal, String? notice}) browserLanded(String target, String landed) =>
    Uri.tryParse(landed)?.host == Uri.tryParse(target)?.host ? _clear : browserTarget(landed);

/// [host] as a person reads it (Dart's Uri percent-encodes non-ASCII hosts).
String _shownHost(String host) {
  try {
    return Uri.decodeComponent(host);
  } on Object {
    return host;
  }
}

/// The agent's own machine or network: localhost, loopback, private and link-local addresses, `.local` names.
bool _localHost(String host) {
  final h = host.toLowerCase();
  if (h.isEmpty || h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return true;
  final ip = InternetAddress.tryParse(h);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 0 || b[0] == 10 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168);
  }
  return b[0] & 0xfe == 0xfc; // fc00::/7 unique local
}

/// Actions whose result carries text the page controls (its title, an eval result, the console, a hit's class names).
const _pageTextActions = {'open', 'eval', 'screenshot', 'console', 'click'};

const _page = 'browser page';

/// A browser action's result text: what was done ([did]) and the page's log
/// since the last call, in an untrusted block when any of it comes from the
/// page.
String browserResultText(String action, String did, List<String> log) {
  final text = [
    did,
    if (log.isNotEmpty) 'Page log:\n${log.join('\n')}' else if (action == 'console') '(nothing logged)',
  ].join('\n');
  return log.isEmpty && !_pageTextActions.contains(action) ? text : untrusted(text, source: _page);
}

/// A failed browser action's text. The message of a page-text action (an
/// eval that threw, a click hit) can quote the page, so it goes in the block
/// with the page log; otherwise only the log does.
String browserErrorText(String action, String message, List<String> log) {
  final logText = log.isEmpty ? '' : 'Page log:\n${log.join('\n')}';
  if (_pageTextActions.contains(action)) {
    return 'Error: the browser action failed.\n${untrusted([message, if (logText.isNotEmpty) logText].join('\n'), source: _page)}';
  }
  return 'Error: ${stripHidden(message)}${logText.isEmpty ? '' : '\n${untrusted(logText, source: _page)}'}';
}

/// Captures window [w] to `.everyai/scratch/screenshots/` under [root] and
/// returns its picture; [others] more windows matched, which the text
/// mentions.
Future<ToolOutput> captureFor(ScreenWindow w, {required String root, required bool vision, int others = 0}) async {
  final dir = Directory('$root/.everyai/scratch/screenshots')..createSync(recursive: true);
  final path = '${dir.path}/window-${DateTime.now().millisecondsSinceEpoch}.png';
  if (await captureWindow(w.id, path) case final problem?) return ToolOutput('Error: $problem', isError: true);
  final label = windowLabel(w);
  final more = others > 0 ? ' $others other window(s) of this session\'s apps; pick with app.' : '';
  final url = await _pngDataUrl(File(path).readAsBytesSync());
  if (!vision || url == null) {
    return ToolOutput('Saved a screenshot of $label to $path (this model can\'t view images).$more');
  }
  return ToolOutput('Screenshot of $label: $path.$more', images: [(label: path, dataUrl: url)]);
}

/// [imageDataUrl] for a PNG, off the calling isolate: shrinking a Retina
/// window's picture takes long enough to freeze the app's UI.
Future<String?> _pngDataUrl(List<int> png) => Isolate.run(() => imageDataUrl(png, 'png'));
