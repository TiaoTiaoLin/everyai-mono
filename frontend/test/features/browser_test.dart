import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/screen_windows.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives a real headless Chrome; skipped where none is installed.
void main() {
  final chrome = HeadlessBrowser.find();
  late Directory tmp;
  late HeadlessBrowser browser;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('browser');
    browser = HeadlessBrowser(profileDir: '${tmp.path}/profile');
  });
  tearDown(() async {
    await browser.close();
    tmp.deleteSync(recursive: true);
  });

  test(
    'opens a file, clicks like a user, types, reads the console and takes a screenshot',
    () async {
      final page = File('${tmp.path}/app.html')
        ..writeAsStringSync('''
<!doctype html><title>Counter</title>
<button id="inc" style="width:120px;height:40px">+1</button>
<input id="name"><p id="out">0</p>
<script>
let n = 0;
document.getElementById('inc').addEventListener('click', () => {
  n++; document.getElementById('out').textContent = n; console.log('clicked', n);
});
document.getElementById('name').addEventListener('keydown', e => { if (e.key === 'Enter') console.log('hello', e.target.value); });
setTimeout(() => { throw new Error('boom'); }, 10);
</script>''');
      expect(await browser.open(page.uri.toString()), startsWith('Counter'));
      expect(await browser.click(selector: '#inc'), contains('button#inc'));
      await browser.click(selector: '#inc', count: 2);
      expect(await browser.evaluate('document.getElementById("out").textContent'), '3');
      await browser.type('Ada', selector: '#name', submit: true);
      final log = browser.takeLog();
      expect(log, contains('console.log: clicked 1'));
      expect(log, contains('console.log: hello Ada'));
      expect(log.any((l) => l.startsWith('Uncaught: Error: boom')), isTrue);
      expect(browser.takeLog(), isEmpty);
      final png = await browser.screenshot();
      expect(png.sublist(1, 4), 'PNG'.codeUnits);
      await expectLater(browser.click(selector: '#missing'), throwsA(isA<BrowserError>()));
    },
    skip: chrome == null ? 'no Chrome installed' : null,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'the browser tool opens a bare path, reports the page log, and shows a screenshot',
    () async {
      File('${tmp.path}/index.html').writeAsStringSync(
        '<!doctype html><title>Desk</title><button id="go">Go</button>'
        '<script>document.getElementById("go").onclick = () => console.error("broken handler");</script>',
      );
      final runner = _runner(tmp, browser);
      final opened = await runner.run('browser', {'action': 'open', 'url': '${tmp.path}/index.html'});
      // The page's title is the page's text: marked untrusted.
      expect(opened.text, startsWith('<untrusted-content source="browser page">\nOpened Desk'));
      final clicked = await runner.run('browser', {'action': 'click', 'selector': '#go', 'screenshot': true});
      expect(clicked.text, contains('console.error: broken handler'));
      expect(clicked.images.single.dataUrl, startsWith('data:image/png;base64,'));
      expect(Directory('${tmp.path}/.everyai/scratch/screenshots').listSync(), hasLength(1));
      final missing = await runner.run('browser', {'action': 'click', 'selector': '#nope'});
      expect(missing.isError, isTrue);
    },
    skip: chrome == null ? 'no Chrome installed' : null,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  group('never types or submits passwords and payment details', () {
    late String url;
    setUp(() {
      url =
          (File('${tmp.path}/forms.html')..writeAsStringSync('''
<!doctype html><title>Forms</title>
<form id="login" action="done.html"><input id="user"><input id="pw" type="password"><button id="signin">Sign in</button></form>
<form id="pay" action="done.html"><input id="cc" autocomplete="cc-number"><input id="cvv" name="cvv2"><input id="iban" name="iban"></form>
<form id="search" action="done.html"><input id="q" name="q"><button id="go" style="width:80px;height:30px">Go</button></form>
<input id="name"><input id="cardtitle" name="card-title">
<iframe id="stripe" title="Secure card payment input frame" srcdoc="<input>"></iframe>
'''))
              .uri
              .toString();
      File('${tmp.path}/done.html').writeAsStringSync('<!doctype html><title>Done</title>');
    });
    Future<Object?> value(String id) => browser.evaluate('document.getElementById("$id").value');

    test(
      'type, press and click',
      () async {
        await browser.open(url);
        for (final id in ['pw', 'cc', 'cvv', 'iban']) {
          await expectLater(
            browser.type('secret', selector: '#$id'),
            throwsA(isA<BrowserError>().having((e) => e.message, 'message', startsWith('Refused: the field is a '))),
          );
          expect(await value(id), '', reason: id);
        }
        // Plain fields, and "card" alone (a kanban card), still take text.
        await browser.type('Ada', selector: '#name');
        await browser.type('Todo', selector: '#cardtitle');
        expect([await value('name'), await value('cardtitle')], ['Ada', 'Todo']);
        // One character at a time is the same.
        await browser.click(selector: '#pw');
        await expectLater(browser.press('a'), throwsA(_refused));
        expect(await value('pw'), '');
        // The user name is fine, but Enter or the button would send the password's form.
        await browser.type('ada', selector: '#user');
        await expectLater(browser.press('Enter'), throwsA(_refused));
        await expectLater(browser.type('x', selector: '#user', submit: true), throwsA(_refused));
        await expectLater(browser.click(selector: '#signin'), throwsA(_refused));
        final at = await browser.evaluate(
          '(() => { const r = document.getElementById("signin").getBoundingClientRect(); '
          'return [r.left + r.width / 2, r.top + r.height / 2]; })()',
        );
        final xy = (at! as List).cast<num>();
        await expectLater(
          browser.click(x: xy[0].toDouble(), y: xy[1].toDouble()),
          throwsA(isA<BrowserError>().having((e) => e.message, 'message', contains('a password field'))),
        );
        // Space on the focused button presses it just the same.
        await browser.evaluate('document.getElementById("signin").focus()');
        await expectLater(
          browser.press('Space'),
          throwsA(isA<BrowserError>().having((e) => e.message, 'message', contains('Space would press a button'))),
        );
        expect(await browser.describe(), startsWith('Forms'));
        // A payment frame we can't look into counts by its name.
        await browser.evaluate('document.getElementById("stripe").focus()');
        await expectLater(browser.type('4242'), throwsA(_refused));
        // A plain form submits.
        await browser.type('flutter', selector: '#q', submit: true);
        await browser.wait(selector: 'title');
        expect(await browser.evaluate('location.pathname.endsWith("done.html")'), isTrue);
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'through the tool, a refusal is an error in plain words',
      () async {
        final runner = _runner(tmp, browser);
        await runner.run('browser', {'action': 'open', 'url': url});
        final typed = await runner.run('browser', {'action': 'type', 'selector': '#pw', 'text': 'hunter2'});
        expect(typed.isError, isTrue);
        expect(typed.text, contains('Refused: the field is a password field.'));
        expect(typed.text, contains('the user does that'));
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });

  test(
    "downloads land in the session's scratch folder, also after another page",
    () async {
      File('${tmp.path}/dl.html').writeAsStringSync(
        '<!doctype html><title>Get</title>'
        '<a id="get" download="notes.txt" href="data:text/plain,hi" style="display:block;width:80px;height:30px">Get</a>',
      );
      final runner = _runner(tmp, browser);
      final dir = '${tmp.path}/.everyai/scratch/downloads';
      for (final round in [1, 2]) {
        await runner.run('browser', {'action': 'open', 'url': '${tmp.path}/dl.html'});
        final landed = browser.events.firstWhere(
          (e) => e.method == 'Browser.downloadProgress' && e.params['state'] == 'completed',
        );
        final clicked = await runner.run('browser', {'action': 'click', 'selector': '#get'});
        await landed;
        // In the click's own log, or the next one's when the download began late.
        final log = '${clicked.text}\n${browser.takeLog().join('\n')}';
        expect(log, contains('Downloaded '), reason: 'round $round');
        expect(log, contains('scratch/downloads/notes'), reason: 'round $round');
      }
      expect(Directory(dir).listSync().map((f) => f.uri.pathSegments.last), contains('notes.txt'));
      expect(File('$dir/notes.txt').readAsStringSync(), 'hi');
    },
    skip: chrome == null ? 'no Chrome installed' : null,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  group('pages from a server', () {
    late HttpServer app;
    late HttpServer other;
    setUp(() async {
      app = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // Framed by another origin: Dart's default X-Frame-Options would refuse that.
      other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        ..defaultResponseHeaders.clear();
      app.listen((req) {
        final res = req.response..headers.contentType = ContentType.html;
        if (req.uri.path == '/big.bin') {
          // A download that never ends.
          res
            ..headers.contentType = ContentType.binary
            ..headers.set('content-disposition', 'attachment; filename="big.bin"')
            ..add(List.filled(1024, 0));
          unawaited(res.flush());
          return;
        }
        res
          ..write(
            '<!doctype html><title>App</title>'
            '<iframe id="auth" style="display:block;width:300px;height:100px;border:0" '
            'src="http://${req.uri.queryParameters['frame'] ?? '127.0.0.1'}:${other.port}/"></iframe>'
            '<a id="big" href="/big.bin" style="display:block;width:80px;height:30px">Big</a>'
            '<button id="inc" style="width:80px;height:30px">+1</button>',
          )
          ..close();
      });
      // Another origin (another port): the page's script can't look inside.
      other.listen((req) {
        req.response
          ..headers.contentType = ContentType.html
          ..write(
            '<!doctype html><body style="margin:0">'
            '<input id="pw" type="password" style="display:block;width:200px;height:40px">'
            '<input id="name" style="display:block;width:200px;height:40px">',
          )
          ..close();
      });
    });
    tearDown(() async {
      await browser.close();
      await app.close(force: true);
      await other.close(force: true);
    });

    test(
      'a frame from another origin is checked inside: no password, but its plain fields take text',
      () async {
        // The same site (one process), and another site (the frame runs in its own process).
        for (final host in ['127.0.0.1', 'localhost']) {
          await browser.open('http://127.0.0.1:${app.port}/?frame=$host');
          final frame = await browser.evaluate(
            '(() => { const r = document.getElementById("auth").getBoundingClientRect(); return [r.left, r.top]; })()',
          );
          final at = (frame! as List).cast<num>();
          await browser.click(x: at[0] + 100.0, y: at[1] + 20.0);
          await expectLater(
            browser.type('secret'),
            throwsA(isA<BrowserError>().having((e) => e.message, 'message', contains('a password field'))),
            reason: host,
          );
          await expectLater(browser.press('a'), throwsA(_refused), reason: host);
          await browser.click(x: at[0] + 100.0, y: at[1] + 60.0);
          expect(await browser.type('Ada'), 'Typed 3 characters.', reason: host);
        }
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'a download that never ends holds only the click that started it',
      () async {
        browser.downloadWait = const Duration(seconds: 1);
        await browser.open('http://127.0.0.1:${app.port}/');
        final began = browser.events.firstWhere((e) => e.method == 'Browser.downloadWillBegin');
        await browser.click(selector: '#big');
        await began;
        browser.takeLog();
        await browser.click(selector: '#inc');
        await browser.press('Tab');
        expect(browser.takeLog().where((l) => l.startsWith('Download still running')), isEmpty);
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });

  test('screenshot never takes a window this session did not start', () async {
    // The user's apps on screen; nothing of the session's among them.
    const windows = [
      (id: 1, pid: 10, owner: 'Mail', title: 'Inbox', width: 900, height: 700),
      (id: 2, pid: 11, owner: 'Notes', title: '', width: 600, height: 500),
      (id: 3, pid: 12, owner: '1Password', title: 'Vault', width: 700, height: 500),
    ];
    Future<WindowPick> pick({String? app}) => pickSessionWindow(
      windows,
      pids: const {99},
      root: tmp.path,
      executableOf: (pid) async => '/Applications/x.app/Contents/MacOS/x',
      app: app,
    );
    expect(await pick(), isA<NoWindow>());
    // Named, it is someone else's: the EveryAI harness only captures an OwnWindow.
    expect(await pick(app: 'mail'), isA<ForeignWindow>());
    // A password manager is never even foreign: the tool says it skipped it.
    final vault = await pick(app: '1password');
    expect((vault as NoWindow).skipped, ['1Password (a password manager)']);
    expect(skippedText(vault.skipped), startsWith('Skipped 1Password (a password manager): EveryAI never captures'));
  });
}

final _refused = isA<BrowserError>().having((e) => e.message, 'message', startsWith('Refused: '));

ToolRunner _runner(Directory tmp, HeadlessBrowser browser) => ToolRunner(
  root: tmp.path,
  shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
  gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
  sessionTag: 't',
  vision: true,
  browser: browser,
);
