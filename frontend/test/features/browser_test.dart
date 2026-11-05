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
      final runner = ToolRunner(
        root: tmp.path,
        shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
        gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
        sessionTag: 't',
        vision: true,
        browser: browser,
      );
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

  test('screenshot never takes a window this session did not start', () async {
    // The user's apps on screen; nothing of the session's among them.
    const windows = [
      (id: 1, pid: 10, owner: 'Mail', title: 'Inbox', width: 900, height: 700),
      (id: 2, pid: 11, owner: 'Notes', title: '', width: 600, height: 500),
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
  });
}
