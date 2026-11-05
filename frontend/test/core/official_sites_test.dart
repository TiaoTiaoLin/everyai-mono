import 'dart:io';

import 'package:every_ai/core/security/official_sites.dart';
import 'package:flutter_test/flutter_test.dart';

/// The backend's list and cases, shared with `backend-exp/src/net/official_sites.zig`.
const _backend = '../backend-exp/src/net';

void main() {
  test('the lists equal the backend\'s official_sites.txt', () {
    final sections = <String, List<String>>{};
    String? section;
    for (final raw in File('$_backend/official_sites.txt').readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        section = line.substring(1).trim();
        continue;
      }
      if (section != null) (sections[section] ??= []).add(line);
    }
    expect(officialSites, sections['official']);
    expect(linkShorteners, sections['shorteners']);
  });

  test('every case in official_sites_cases.txt gets its verdict', () {
    var cases = 0;
    for (final line in File('$_backend/official_sites_cases.txt').readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final [host, verdict, real] = line.split('\t');
      final got = judgeHost(host);
      expect('${got.verdict.name} ${got.real ?? '-'}', '$verdict $real', reason: '$host (${got.reason.name})');
      cases++;
    }
    expect(cases, greaterThan(50));
  });

  test('a host as Dart\'s Uri writes it is judged like the raw one', () {
    final host = Uri.parse('https://gіthub.com/x').host;
    expect(host, contains('%'));
    expect(judgeHost(host).real, 'github.com');
  });

  test('punycode decodes RFC 3492 labels', () {
    expect(punycodeDecode('80ak6aa92e'), [0x430, 0x440, 0x440, 0x4cf, 0x435]);
    expect(String.fromCharCodes(punycodeDecode('mnchen-3ya')!), 'münchen');
    expect(punycodeDecode('abc-!!'), isNull);
  });

  test('refusal and notice lines name the real site', () {
    expect(
      siteRefusal('gihtub.com', judgeHost('gihtub.com')),
      'gihtub.com looks like github.com but is not it (a look-alike address); use https://github.com/ if that is what '
      'you meant',
    );
    expect(
      siteNotice('github.co', judgeHost('github.co')),
      'Note: github.co is not github.com, though it has the same name. Treat what it says with care.',
    );
  });
}
