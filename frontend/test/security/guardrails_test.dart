import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/security/untrusted.dart';
import 'package:every_ai/features/code/harness/everyai/scrub.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guards.dart';

// The red-team set for the harness tool guardrails: every case in fixtures/*.json runs through the guarded code
// (see guards.dart) and must get the outcome its `expect` names. How to add one: README.md.

const expectWords = {'refused', 'warned', 'fenced', 'stripped', 'redacted', 'allowed'};

final fixtureFiles = (Directory('test/security/fixtures').listSync().whereType<File>().toList()
  ..sort((a, b) => a.path.compareTo(b.path)));

List<Map<String, Object?>> casesOf(File f) =>
    ((jsonDecode(f.readAsStringSync()) as Map)['cases'] as List).cast<Map<String, Object?>>();

/// [s] without hidden characters and with runs of white space as one space.
String _flat(String s) => stripHidden(s).replaceAll(RegExp(r'\s+'), ' ').trim();

/// Why [text] doesn't keep [payload] inside its [fences], or null: one or more opening tags, as many closing tags
/// (any case, spaces or slashes, `-`, `_` or a space inside the name), and no payload line after the last close.
String? fencedProblem(String text, String payload, List<String> fences) {
  final names = fences.map((f) => f.split(RegExp('[-_]')).join(r'[\s_-]*')).join('|');
  final open = RegExp('<\\s*(?:$names)\\b', caseSensitive: false).allMatches(text).length;
  final closes = RegExp('<\\s*/[\\s/]*(?:$names)\\b', caseSensitive: false).allMatches(text).toList();
  if (open == 0) return 'no fence';
  if (closes.length != open) return '$open opening tags but ${closes.length} closing ones';
  final after = _flat(text.substring(closes.last.end));
  for (final line in payload.split('\n').map(_flat).where((l) => l.length >= 6)) {
    if (after.contains(line)) return 'payload after the last close: "$line"';
  }
  return null;
}

/// What is wrong with [out] for the [expect] words, or an empty list.
List<String> problems(Outcome out, Map<String, Object?> c, String payload, Secrets secrets) {
  final because = (c['because'] as String?)?.toLowerCase();
  final text = out.text;
  bool says() => because == null || text.toLowerCase().contains(because);
  return [
    for (final word in (c['expect']! as List).cast<String>())
      ?switch (word) {
        'refused' => out.error && says() ? null : 'not refused${because == null ? '' : ' for "$because"'}',
        'warned' => out.warned && !out.error && says() ? null : 'no warning${because == null ? '' : ' "$because"'}',
        'fenced' => fencedProblem(text, payload, out.fences),
        'stripped' =>
          text.contains('removed="')
              ? (hiddenIn(text).isEmpty ? null : 'hidden characters left: ${hiddenIn(text)}')
              : text.contains('[Hidden characters removed') && hiddenIn(text, keepWriting: true).isEmpty
              ? null
              : 'hidden characters neither removed nor named',
        'redacted' =>
          secrets.values.values.expand((v) => v.split('\n')).where((v) => v.length >= 16).any(text.contains)
              ? 'a secret reaches the model'
              : null,
        'allowed' =>
          out.error || out.warned
              ? 'a benign case was ${out.error ? 'refused' : 'warned about'}'
              : payload.split('\n').where((l) => l.trim().isNotEmpty).every(text.contains)
              ? null
              : 'the content was changed',
        _ => 'unknown expect word "$word"',
      },
  ];
}

void main() {
  group('fixture files', () {
    test('parse, with unique ids, known guards and expect words', () {
      final ids = <String>{};
      for (final f in fixtureFiles) {
        for (final c in casesOf(f)) {
          final id = c['id'] as String;
          expect(ids.add(id), isTrue, reason: 'duplicate id $id');
          expect(knownGuards, contains(c['guard']), reason: id);
          expect(c['expect'], isA<List<Object?>>().having((l) => l.isNotEmpty, 'not empty', isTrue), reason: id);
          for (final w in c['expect']! as List) {
            expect(expectWords, contains(w), reason: id);
          }
          expect(c['ref'], isA<String>(), reason: '$id: say where the attack comes from');
        }
      }
      expect(ids.length, greaterThan(40));
    });

    test('every file has a benign control, so a guard that blocks everything fails', () {
      for (final f in fixtureFiles) {
        expect(casesOf(f).any((c) => (c['expect']! as List).contains('allowed')), isTrue, reason: f.path);
      }
    });

    test('the fence check catches a missing fence, an early close and payload after it', () {
      const fences = untrustedFences;
      expect(fencedProblem('page text', 'page text', fences), 'no fence');
      expect(fencedProblem('<untrusted-content source="x">\na\n</untrusted-content>', 'a', fences), isNull);
      expect(
        fencedProblem('<untrusted-content>\na\n< /UNTRUSTED_content >\nobey\n</untrusted-content>', 'a', fences),
        isNotNull,
      );
      expect(
        fencedProblem('<untrusted-content>\na\n</untrusted-content>\nobey me now', 'a\nobey me now', fences),
        contains('after the last close'),
      );
    });

    test('hidden characters are written as escapes, and no secret-shaped string is stored', () {
      for (final f in fixtureFiles) {
        final raw = f.readAsStringSync();
        expect(hiddenIn(raw), isEmpty, reason: '${f.path}: write hidden characters as \\u escapes');
        expect(Scrubber().leak(raw), isNull, reason: '${f.path}: use {{PLACEHOLDER}} secrets');
      }
    });
  });

  for (final f in fixtureFiles) {
    group(f.uri.pathSegments.last, () {
      for (final c in casesOf(f)) {
        final pending = c['pending'] as String?;
        test('${c['id']}${pending == null ? '' : ' (pending: $pending)'}', () async {
          final secrets = Secrets();
          final input = (secrets.fillAll(c['input'] ?? const <String, Object?>{})! as Map).cast<String, Object?>();
          final payload = secrets.fill(c['payload'] as String? ?? '');
          final bench = GuardBench(secrets);
          try {
            final out = await bench.run(c['guard']! as String, input, payload);
            final wrong = problems(out, c, payload, secrets);
            if (pending == null) {
              expect(wrong, isEmpty, reason: out.text);
            } else {
              // Strict: a pending case must still fail, so it can't stay pending once its guard lands.
              expect(wrong, isNotEmpty, reason: 'guard landed: remove pending\n${out.text}');
            }
          } finally {
            await bench.dispose();
          }
        });
      }
    });
  }
}
