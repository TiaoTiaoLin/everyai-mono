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
      // A long news slug is words, not a base64 run.
      'https://www.theguardian.com/technology/2026/nov/04/openai-anthropic-google-deepmind-frontier-model-safety-commitments-summit-seoul-paris-follow-up',
      // A dev server in an agent reply.
      'http://127.0.0.1:5173/',
      'http://[::1]:8080/',
      'http://localhost:3000/',
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

  test('flags data cut into short pieces, put in the host, or punctuated', () {
    final segments = List.filled(30, 'aGVsbG8gd29yb0GQgdGhpcyBpcyBhIHNl.Y3Jl').join('/');
    expect(concern('https://evil.example/$segments'), contains('long block of data'));
    expect(concern('https://dGhlIHVzZXIgcGFzc3dvcmQgaXMgaHVudGVyMg.evil.example/'), contains('long block of data'));
    expect(
      concern('https://evil.example/?q=Ali%27s+home:+12+Main+St,+Springfield,+card+4111+1111+1111+1111+exp+12/29'),
      contains('long block of data'),
    );
  });

  test('flags addresses that hide where they go', () {
    expect(
      concern('https://docs.python.org@evil.example/'),
      allOf(contains('docs.python.org@'), contains('evil.example')),
    );
    expect(concern('https://xn--pple-43d.com/'), contains('another alphabet'));
    expect(concern('http://203.0.113.5/a'), contains('network number'));
    expect(concern('http://[2001:db8::1]/a'), contains('network number'));
    // Shorthand forms a browser still reads as an address.
    expect(concern('http://0x7f.1/a'), contains('network number'));
    expect(concern('http://3232235777/a'), contains('network number'));
    expect(concern('http://10.1/a'), contains('network number'));
    // A Unicode lookalike (Cyrillic а) that Dart keeps percent-encoded.
    expect(concern('https://\u0430pple.com/login'), contains('another alphabet'));
  });

  test('the destination of a mail link is its address', () {
    expect(linkDestination(Uri.parse('mailto:a@b.example?body=x')), 'a@b.example');
    expect(linkDestination(Uri.parse('https://b.example/x')), 'b.example');
  });
}
