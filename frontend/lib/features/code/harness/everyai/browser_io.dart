// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'shell_io.dart' show killTree;

/// A headless Chrome the session owns, driven over the DevTools protocol:
/// its own profile under the session's scratch folder (never the user's
/// browser or cookies), started on first use and stopped with the session.
/// The agent opens pages (`http://localhost…`, `file://…`), clicks and types
/// like a user (real mouse and key events), takes screenshots, runs scripts
/// and reads what the page logged. It never types into password or payment
/// fields nor submits their forms ([_guardJs]), and its downloads land in
/// [downloadDir].
final class HeadlessBrowser {
  HeadlessBrowser({required this.profileDir, this.executable});

  /// Where the browser keeps its profile (cookies, storage) for this session.
  final String profileDir;

  /// The browser to run; null finds Chrome, Chromium, Edge or Brave.
  final String? executable;

  /// Where downloads go, set before the browser starts (the session's scratch
  /// folder); null refuses downloads.
  String? downloadDir;

  Process? _process;
  // Closed in close().
  // ignore: close_sinks
  WebSocket? _socket;
  // The browser-level connection: the download folder holds while it is open.
  // Closed in close().
  // ignore: close_sinks
  WebSocket? _browserSocket;

  /// Downloads started and not yet finished, by guid, with their file names.
  final _downloads = <String, String>{};
  Completer<void>? _downloadsDone;
  var _nextId = 0;
  final _calls = <int, Completer<Map<String, Object?>>>{};
  // Lives as long as this object: the browser may start again after close.
  // ignore: close_sinks
  final _events = StreamController<({String method, Map<String, Object?> params})>.broadcast();

  /// Console messages, uncaught errors and failed requests since the last read.
  final _log = <String>[];

  /// Width and height of the viewport, in CSS pixels.
  var width = 1280;
  var height = 800;

  bool get running => _socket != null;

  /// Where a Chromium-family browser is installed, or null.
  static String? find() {
    final env = Platform.environment['EVERYAI_CHROME'];
    if (env != null && File(env).existsSync()) return env;
    final home = Platform.environment['HOME'] ?? '';
    final candidates = <String>[
      if (Platform.isMacOS) ...[
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '$home/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
        '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
      ],
      if (Platform.isLinux)
        for (final dir in ['/usr/bin', '/usr/local/bin', '/snap/bin'])
          for (final name in [
            'google-chrome',
            'google-chrome-stable',
            'chromium',
            'chromium-browser',
            'microsoft-edge',
          ])
            '$dir/$name',
      if (Platform.isWindows) ...[
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      ],
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  Future<void> _start() async {
    if (_socket != null) return;
    final exe = executable ?? find();
    if (exe == null) {
      throw const BrowserError(
        'No Chrome, Chromium, Edge or Brave found. Install one (or set EVERYAI_CHROME to its path), or check the '
        'page another way.',
      );
    }
    Directory(profileDir).createSync(recursive: true);
    final process = await Process.start(exe, [
      '--headless=new',
      '--remote-debugging-port=0',
      '--user-data-dir=$profileDir',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--disable-background-networking',
      // Never the user's Keychain or keyring.
      '--use-mock-keychain',
      '--password-store=basic',
      '--hide-scrollbars',
      '--mute-audio',
      '--window-size=$width,$height',
      'about:blank',
    ]);
    _process = process;
    unawaited(process.stdout.drain<void>());
    // Chrome says where its DevTools endpoint is on stderr.
    final endpoint = Completer<Uri>();
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final m = RegExp(r'DevTools listening on (ws://\S+)').firstMatch(line);
      if (m != null && !endpoint.isCompleted) endpoint.complete(Uri.parse(m[1]!));
    }, onError: (Object _) {});
    unawaited(
      process.exitCode.then((_) {
        if (!endpoint.isCompleted) endpoint.completeError(const BrowserError('The browser exited at start.'));
        _closed();
      }),
    );
    final browserWs = await endpoint.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw const BrowserError('The browser did not start within 20 s.'),
    );
    // The page target (about:blank) has its own socket: commands go to it
    // without per-target sessions.
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('http://${browserWs.host}:${browserWs.port}/json/list'));
      final res = await req.close();
      final list = jsonDecode(await res.transform(utf8.decoder).join()) as List<Object?>;
      final page = list.whereType<Map<String, Object?>>().firstWhere(
        (t) => t['type'] == 'page',
        orElse: () => throw const BrowserError('The browser has no page to drive.'),
      );
      _socket = await WebSocket.connect(page['webSocketDebuggerUrl']! as String);
    } finally {
      client.close(force: true);
    }
    _socket!.listen(_onFrame, onDone: _closed, onError: (Object _) => _closed());
    _browserSocket = await WebSocket.connect(browserWs.toString());
    _browserSocket!.listen(_onFrame, onError: (Object _) {});
    final dir = downloadDir;
    if (dir != null) Directory(dir).createSync(recursive: true);
    await Future.wait([
      _send('Page.enable'),
      _send('Runtime.enable'),
      _send('Log.enable'),
      _send('Network.enable'),
      _sendOn(_browserSocket, 'Browser.setDownloadBehavior', {
        'behavior': dir == null ? 'deny' : 'allow',
        'downloadPath': ?dir,
        'eventsEnabled': true,
      }),
    ]);
    await _viewport();
  }

  void _onFrame(Object? frame) {
    if (frame is! String) return;
    final Map<String, Object?> msg;
    try {
      msg = jsonDecode(frame) as Map<String, Object?>;
    } on Object {
      return;
    }
    if (msg['id'] case final int id) {
      final c = _calls.remove(id);
      if (c == null) return;
      if (msg['error'] case final Map<String, Object?> e) {
        c.completeError(BrowserError('${e['message'] ?? e}'));
      } else {
        c.complete((msg['result'] as Map<String, Object?>?) ?? const {});
      }
      return;
    }
    final method = msg['method'] as String? ?? '';
    final params = (msg['params'] as Map<String, Object?>?) ?? const {};
    _record(method, params);
    _events.add((method: method, params: params));
  }

  /// Keeps what a developer would look for in the console.
  void _record(String method, Map<String, Object?> p) {
    String? line;
    switch (method) {
      case 'Runtime.consoleAPICalled':
        final args = [
          for (final a in (p['args'] as List<Object?>? ?? const []))
            if (a is Map<String, Object?>) '${a['value'] ?? a['description'] ?? a['type']}',
        ].join(' ');
        line = 'console.${p['type']}: $args';
      case 'Runtime.exceptionThrown':
        final d = p['exceptionDetails'] as Map<String, Object?>? ?? const {};
        final ex = d['exception'] as Map<String, Object?>?;
        line =
            'Uncaught: ${ex?['description'] ?? d['text']}'
            '${d['url'] == null ? '' : ' (${d['url']}:${d['lineNumber']})'}';
      case 'Log.entryAdded':
        final e = p['entry'] as Map<String, Object?>? ?? const {};
        if (e['level'] == 'error' || e['level'] == 'warning') line = '${e['level']}: ${e['text']} ${e['url'] ?? ''}';
      case 'Network.loadingFailed':
        if (p['canceled'] != true) line = 'Request failed: ${p['errorText']} (${p['type'] ?? ''})';
      case 'Network.responseReceived':
        final r = p['response'] as Map<String, Object?>? ?? const {};
        final status = (r['status'] as num?)?.toInt() ?? 0;
        if (status >= 400) line = 'HTTP $status: ${r['url']}';
      case 'Browser.downloadWillBegin':
        _downloads['${p['guid']}'] = '${p['suggestedFilename'] ?? 'download'}';
        _downloadsDone ??= Completer<void>();
      case 'Browser.downloadProgress':
        final state = p['state'];
        if (state != 'completed' && state != 'canceled') break;
        final name = _downloads.remove('${p['guid']}') ?? 'download';
        line = state == 'completed'
            ? 'Downloaded ${p['filePath'] ?? '$downloadDir/$name'}'
            : 'Download canceled: $name${downloadDir == null ? ' (this browser takes no downloads)' : ''}';
        if (_downloads.isEmpty) {
          _downloadsDone?.complete();
          _downloadsDone = null;
        }
    }
    if (line == null) return;
    _log.add(line.length > 600 ? '${line.substring(0, 600)}…' : line);
    if (_log.length > 200) _log.removeRange(0, _log.length - 200);
  }

  void _closed() {
    _socket = null;
    unawaited(_browserSocket?.close());
    _browserSocket = null;
    _downloads.clear();
    _downloadsDone?.complete();
    _downloadsDone = null;
    for (final c in _calls.values) {
      if (!c.isCompleted) c.completeError(const BrowserError('The browser closed.'));
    }
    _calls.clear();
  }

  Future<Map<String, Object?>> _send(String method, [Map<String, Object?> params = const {}]) =>
      _sendOn(_socket, method, params);

  /// Sends [method] on [socket]: the page's, or the browser's own.
  Future<Map<String, Object?>> _sendOn(WebSocket? socket, String method, Map<String, Object?> params) {
    if (socket == null) return Future.error(const BrowserError('The browser is not running.'));
    final id = ++_nextId;
    final c = Completer<Map<String, Object?>>();
    _calls[id] = c;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return c.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _calls.remove(id);
        throw BrowserError('$method took longer than 30 s.');
      },
    );
  }

  Future<void> _viewport() => _send('Emulation.setDeviceMetricsOverride', {
    'width': width,
    'height': height,
    'deviceScaleFactor': 1,
    'mobile': false,
  });

  /// What the page logged since the last call; cleared on read.
  List<String> takeLog() {
    final out = [..._log];
    _log.clear();
    return out;
  }

  Future<String> open(String url) async {
    await _start();
    final loaded = _events.stream.firstWhere((e) => e.method == 'Page.loadEventFired');
    final r = await _send('Page.navigate', {'url': url});
    if (r['errorText'] case final String e when e.isNotEmpty) throw BrowserError('Could not open $url: $e');
    await loaded.timeout(const Duration(seconds: 20), onTimeout: () => (method: '', params: const <String, Object?>{}));
    // A moment for scripts that run after load (frameworks mounting).
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return describe();
  }

  /// The page's address and title.
  Future<String> describe() async {
    final v = await evaluate('JSON.stringify({url: location.href, title: document.title})');
    final m = jsonDecode(v as String) as Map<String, Object?>;
    return '${m['title']} — ${m['url']}';
  }

  Future<Object?> evaluate(String script) async {
    await _start();
    final r = await _send('Runtime.evaluate', {
      'expression': script,
      'returnByValue': true,
      'awaitPromise': true,
      'userGesture': true,
    });
    if (r['exceptionDetails'] case final Map<String, Object?> d) {
      final ex = d['exception'] as Map<String, Object?>?;
      throw BrowserError('The script threw: ${ex?['description'] ?? d['text']}');
    }
    return (r['result'] as Map<String, Object?>?)?['value'];
  }

  /// PNG bytes of the viewport, or of the whole page with [fullPage].
  Future<List<int>> screenshot({bool fullPage = false}) async {
    await _start();
    final params = <String, Object?>{'format': 'png'};
    if (fullPage) {
      final m = await _send('Page.getLayoutMetrics');
      final size = (m['cssContentSize'] ?? m['contentSize']) as Map<String, Object?>? ?? const {};
      params['captureBeyondViewport'] = true;
      params['clip'] = {
        'x': 0,
        'y': 0,
        'width': (size['width'] as num?) ?? width,
        // Very long pages are cut at 8000 px.
        'height': (((size['height'] as num?) ?? height).clamp(1, 8000)),
        'scale': 1,
      };
    }
    final r = await _send('Page.captureScreenshot', params);
    return base64Decode(r['data']! as String);
  }

  /// The centre of the first element matching [selector], scrolled into view.
  Future<({double x, double y})> _centre(String selector) async {
    final v = await evaluate('''
(() => {
  const el = document.querySelector(${jsonEncode(selector)});
  if (!el) return null;
  el.scrollIntoView({block: 'center', inline: 'center'});
  const r = el.getBoundingClientRect();
  return {x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height};
})()''');
    if (v is! Map) throw BrowserError('No element matches $selector.');
    if (v['w'] == 0 && v['h'] == 0) throw BrowserError('$selector matches an element with no size (hidden?).');
    return (x: (v['x'] as num).toDouble(), y: (v['y'] as num).toDouble());
  }

  /// A real mouse click (press and release) on [selector] or at [x],[y]: it
  /// goes through overlays the way a user's click would.
  Future<String> click({String? selector, double? x, double? y, int count = 1}) async {
    await _start();
    final at = selector != null ? await _centre(selector) : (x: x ?? 0, y: y ?? 0);
    await _refuse('''
const el = deep(${at.x}, ${at.y});
const c = el && el.closest && el.closest('button, input[type=submit i], input[type=image i]');
const f = c && c.type !== 'button' && c.type !== 'reset' ? c.form : null;
return f && sensitiveForm(f) ? 'that button submits a form with ' + sensitiveForm(f) : null;''');
    await _send('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': at.x, 'y': at.y});
    for (var n = 1; n <= count; n++) {
      for (final type in ['mousePressed', 'mouseReleased']) {
        await _send('Input.dispatchMouseEvent', {
          'type': type,
          'x': at.x,
          'y': at.y,
          'button': 'left',
          'clickCount': n,
        });
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await _settleDownloads();
    final hit = await evaluate(
      '(() => { const e = document.elementFromPoint(${at.x}, ${at.y}); '
      'return e ? e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") + '
      '(e.className && typeof e.className === "string" ? "." + e.className.trim().split(/\\s+/).join(".") : "") : null; })()',
    );
    return 'Clicked at (${at.x.round()}, ${at.y.round()})${hit == null ? '' : ' on $hit'}.';
  }

  /// Types [text] into [selector] (clicked first) or the focused element.
  Future<String> type(String text, {String? selector, bool submit = false}) async {
    await _start();
    if (selector != null) await click(selector: selector);
    await _refuse(
      '''
const el = focused();
const f = $submit && el && (el.form || (el.closest && el.closest('form')));
return sensitive(el) ? 'the field is ' + sensitive(el) : f && sensitiveForm(f) ? 'its form has ' + sensitiveForm(f) : null;''',
    );
    await _send('Input.insertText', {'text': text});
    if (submit) await press('Enter');
    return 'Typed ${text.length} characters${submit ? ' and pressed Enter' : ''}.';
  }

  static const _keys = <String, (String code, int vk, String text)>{
    'Enter': ('Enter', 13, '\r'),
    'Tab': ('Tab', 9, ''),
    'Escape': ('Escape', 27, ''),
    'Backspace': ('Backspace', 8, ''),
    'Delete': ('Delete', 46, ''),
    'Space': ('Space', 32, ' '),
    'ArrowUp': ('ArrowUp', 38, ''),
    'ArrowDown': ('ArrowDown', 40, ''),
    'ArrowLeft': ('ArrowLeft', 37, ''),
    'ArrowRight': ('ArrowRight', 39, ''),
    'Home': ('Home', 36, ''),
    'End': ('End', 35, ''),
    'PageUp': ('PageUp', 33, ''),
    'PageDown': ('PageDown', 34, ''),
  };

  /// A key press: a named key ([_keys]) or one character ("a", "W").
  Future<String> press(String key) async {
    await _start();
    final named = _keys[key];
    final single = named == null && key.length == 1;
    if (named == null && !single) {
      throw BrowserError('Unknown key "$key". Use one of ${_keys.keys.join(', ')} or one character.');
    }
    final upper = single ? key.toUpperCase() : '';
    final base = <String, Object?>{
      'key': key == 'Space' ? ' ' : key,
      'code': named?.$1 ?? (RegExp(r'[a-zA-Z]').hasMatch(key) ? 'Key$upper' : ''),
      'windowsVirtualKeyCode': named?.$2 ?? upper.codeUnitAt(0),
    };
    final text = named?.$3 ?? key;
    if (key == 'Enter') {
      await _refuse('''
const el = focused();
const f = el && (el.form || (el.closest && el.closest('form')));
return f && sensitiveForm(f) ? 'Enter would submit a form with ' + sensitiveForm(f) : null;''');
    } else if (text.isNotEmpty) {
      await _refuse('const el = focused(); return sensitive(el) ? "the field is " + sensitive(el) : null;');
    }
    await _send('Input.dispatchKeyEvent', {
      ...base,
      'type': text.isEmpty ? 'rawKeyDown' : 'keyDown',
      'text': ?(text.isEmpty ? null : text),
    });
    await _send('Input.dispatchKeyEvent', {...base, 'type': 'keyUp'});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _settleDownloads();
    return 'Pressed $key.';
  }

  Future<String> scroll(double dy, {double? x, double? y}) async {
    await _start();
    await _send('Input.dispatchMouseEvent', {
      'type': 'mouseWheel',
      'x': x ?? width / 2,
      'y': y ?? height / 2,
      'deltaX': 0,
      'deltaY': dy,
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final pos = await evaluate('Math.round(window.scrollY)');
    return 'Scrolled; the page is at y=$pos.';
  }

  /// Waits for [selector] to appear (or [ms] to pass).
  Future<String> wait({String? selector, int ms = 5000}) async {
    await _start();
    if (selector == null) {
      await Future<void>.delayed(Duration(milliseconds: ms.clamp(0, 30000)));
      return 'Waited ${ms}ms.';
    }
    final end = DateTime.now().add(Duration(milliseconds: ms.clamp(0, 30000)));
    while (DateTime.now().isBefore(end)) {
      if (await evaluate('!!document.querySelector(${jsonEncode(selector)})') == true) return '$selector is there.';
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw BrowserError('$selector did not appear within ${ms}ms.');
  }

  Future<String> resize(int w, int h) async {
    width = w.clamp(200, 3840);
    height = h.clamp(200, 2400);
    await _start();
    await _viewport();
    return 'The viewport is ${width}x$height.';
  }

  /// Waits (up to 20 s) for the downloads an action started, so its log says
  /// where they landed.
  Future<void> _settleDownloads() async {
    final done = _downloadsDone;
    if (done != null) await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
  }

  /// Throws a refusal when [check] (a function body over [_guardJs]'s
  /// helpers, returning why or null) finds a password or payment field.
  Future<void> _refuse(String check) async {
    final why = await evaluate('(() => { $_guardJs\n$check })()');
    if (why is! String) return;
    throw BrowserError(
      'Refused: $why. The browser tool never types passwords, one-time codes or payment details and never submits '
      'their forms: the user does that. To test a sign-in or checkout of the app you build, check it another way '
      '(a test, or its API) or ask the user.',
    );
  }

  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
    final browserSocket = _browserSocket;
    _browserSocket = null;
    await browserSocket?.close();
    final p = _process;
    _process = null;
    if (p != null) await killTree(p.pid);
  }
}

/// Page helpers for the guards: `sensitive(el)` says what a password, one-time
/// code or payment field is ("a password field") or null; `sensitiveForm(f)`
/// the same for a form holding one; `focused()` is the focused element,
/// through shadow roots and same-origin frames; `deep(x, y)` is the element
/// at a point, through shadow roots. A frame we can't look into counts by its name (Stripe
/// and the like put card fields in their own frame). Names in other languages,
/// canvas fields and div "buttons" are missed: a tripwire, not a sandbox.
const _guardJs = r'''
const cardName = /card.?(number|num)|cardno|card.?no(?![a-z])|ccnum|security.?code|sort.?code|routing.?number|account.?number|(?<![a-z])(cvv|cvc|csc|iban)(?![a-z])/i;
const payFrame = /stripe|braintree|adyen|paypal|checkout|card|payment/i;
const sensitive = (el) => {
  if (!el || !el.tagName) return null;
  const tag = el.tagName.toLowerCase();
  if (tag === 'iframe') {
    return payFrame.test([el.src, el.name, el.title].join(' ')) ? 'in a payment frame' : null;
  }
  if (tag === 'input' && (el.type || '').toLowerCase() === 'password') return 'a password field';
  const ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
  if (ac.includes('current-password') || ac.includes('new-password')) return 'a password field';
  if (ac.includes('one-time-code')) return 'a one-time code field';
  if (ac.some((t) => t.startsWith('cc-'))) return 'a payment card field';
  const names = [el.getAttribute('name'), el.id, el.getAttribute('aria-label')].filter(Boolean).join(' ');
  return cardName.test(names) ? 'a payment field' : null;
};
const sensitiveForm = (f) => {
  for (const el of [...(f.elements || []), ...f.querySelectorAll('iframe')]) {
    const why = sensitive(el);
    if (why) return why === 'in a payment frame' ? 'a payment frame' : why;
  }
  return null;
};
const inside = (el) => {
  try { return el.contentDocument && el.contentDocument.activeElement; } catch (e) { return null; }
};
const focused = () => {
  let el = document.activeElement;
  for (;;) {
    const next = (el && el.shadowRoot && el.shadowRoot.activeElement) || (el && el.tagName === 'IFRAME' && inside(el));
    if (!next || next === el || next.tagName === 'BODY') return el;
    el = next;
  }
};
const deep = (x, y) => {
  let el = document.elementFromPoint(x, y);
  while (el && el.shadowRoot) {
    const under = el.shadowRoot.elementFromPoint(x, y);
    if (!under || under === el) break;
    el = under;
  }
  return el;
};''';

final class BrowserError implements Exception {
  const BrowserError(this.message);
  final String message;
  @override
  String toString() => message;
}
