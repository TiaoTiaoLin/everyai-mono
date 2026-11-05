import 'dart:convert';

import 'package:every_ai/core/security/link_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? concern(String url) => linkConcern(Uri.parse(url));

  test('ordinary links pass', () {
    for (final url in [
      'https://docs.flutter.dev/ui/layout',
      'https://www.google.com/search?q=riverpod+3+migration',
      'https://github.com/xuckless/anole/blob/9fdd4071c0ffee1234567890abcdef1234567890/src/main.zig#L42',
      'https://blog.example.com/how-to-set-up-riverpod-3-with-drift-and-flutter-on-every-platform',
      'mailto:hello@example.com?subject=Hi',
    ]) {
      expect(concern(url), isNull, reason: url);
    }
  });

  test('flags data and secrets in the address', () {
    final blob = base64Url.encode(utf8.encode('the user said: my bank PIN is 4242 and the chat goes on'));
    expect(concern('https://img.example/p.png?d=$blob'), contains('long block of data'));
    expect(concern('https://x.example/sk-proj-abcdefghijklmnopqrstuvwxyz012345/c'), contains('an API key'));
    expect(concern('https://x.example/c?t=ghp_abcdefghijklmnopqrstuvwxyz0123'), contains('a GitHub token'));
    // Percent-encoding doesn't hide it.
    expect(concern('https://x.example/c?t=%73k-proj-abcdefghijklmnopqrstuvwxyz012345'), contains('an API key'));
    expect(concern('https://x.example/#${'Q' * 30}${'7' * 30}'), contains('long block of data'));
    expect(concern('mailto:x@example.com?body=${'word%20' * 60}'), contains('long block of data'));
  });

  test('flags addresses that hide where they go', () {
    expect(
      concern('https://docs.python.org@evil.example/'),
      allOf(contains('docs.python.org@'), contains('evil.example')),
    );
    expect(concern('https://xn--pple-43d.com/'), contains('another alphabet'));
    expect(concern('http://203.0.113.5/a'), contains('network number'));
    expect(concern('http://[2001:db8::1]/a'), contains('network number'));
  });

  test('the destination of a mail link is its address', () {
    expect(linkDestination(Uri.parse('mailto:a@b.example?body=x')), 'a@b.example');
    expect(linkDestination(Uri.parse('https://b.example/x')), 'b.example');
  });
}
