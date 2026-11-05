import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('browserTarget', () {
    test("the agent's own apps are never judged", () {
      for (final t in [
        'file:///tmp/gihtub.com/index.html',
        'http://localhost:3000/',
        'http://app.localhost/',
        'http://127.0.0.1:8080/',
        'http://192.168.1.20/',
        'http://10.0.0.5/',
        'http://[::1]:5173/',
        'http://printer.local/',
        'about:blank',
      ]) {
        expect(browserTarget(t), (refusal: null, notice: null), reason: t);
      }
    });

    test('official and ordinary sites open without a word', () {
      expect(browserTarget('https://github.com/flutter/flutter'), (refusal: null, notice: null));
      expect(browserTarget('https://example.org/'), (refusal: null, notice: null));
    });

    test('a look-alike is refused, naming the real site', () {
      for (final t in ['https://gihtub.com/login', 'https://gіthub.com/', 'https://xn--gthub-n2e.com/']) {
        final r = browserTarget(t).refusal;
        expect(r, contains('looks like github.com'), reason: t);
        expect(r, contains('use https://github.com/'), reason: t);
      }
      // Shown as a person reads it, not percent-encoded.
      expect(browserTarget('https://gіthub.com/').refusal, contains('gіthub.com looks like'));
    });

    test('a bare public IP or a shortener gets a note', () {
      expect(browserTarget('http://93.184.216.34/').notice, startsWith('Note: 93.184.216.34 is a bare IP address'));
      expect(browserTarget('https://bit.ly/x').notice, contains('link shortener'));
    });
  });

  test('where a redirect landed is judged only when the host changed', () {
    expect(browserLanded('https://bit.ly/x', 'https://gihtub.com/login').refusal, contains('looks like github.com'));
    expect(browserLanded('https://bit.ly/x', 'https://github.com/a'), (refusal: null, notice: null));
    // The same host: the note was given before opening.
    expect(browserLanded('http://93.184.216.34/', 'http://93.184.216.34/next'), (refusal: null, notice: null));
  });

  test('open refuses a look-alike before the browser starts', () async {
    final b = HeadlessBrowser(profileDir: '/nonexistent/profile', executable: '/nonexistent/chrome');
    final out = await runBrowser(
      b,
      {'action': 'open', 'url': 'pypl.org/project/requests'},
      root: '/nonexistent',
      vision: false,
      fit: (t, _) => t,
    );
    expect(out.isError, isTrue);
    expect(out.text, contains('pypl.org looks like pypi.org'));
  });
}
