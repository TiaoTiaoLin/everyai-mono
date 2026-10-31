import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/transcript.dart' show stepTitle;
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/skills/data/skill_import.dart';
import 'package:every_ai/features/skills/data/skill_store_io.dart' as store;
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:every_ai/features/slash/skills/skill_draft.dart';
import 'package:every_ai/features/slash/skills/skill_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _valid = '''---
name: make-deck
description: Plan and write a slide deck. Use when the user asks for slides.
license: Apache-2.0
metadata:
  version: "1.0"
  author: someone
---

# Make a deck

Write one idea per slide.
''';

SkillCheck _check(String md, {String dir = 'make-deck', List<SkillEntry>? entries, bool strict = true}) => checkSkill(
  dirName: dir,
  skillMd: md,
  entries: entries ?? [SkillEntry('SKILL.md', size: md.length)],
  strict: strict,
);

InstalledSkill _installed(
  String name, {
  SkillSource source = SkillSource.library,
  String? projectId,
  String digest = 'd1',
  String description = 'Does a thing. Use it when asked.',
}) {
  final md = '---\nname: $name\ndescription: $description\n---\nBody of $name.\n';
  final c = checkSkill(dirName: name, skillMd: md, entries: const [SkillEntry('SKILL.md', size: 10)]);
  return InstalledSkill(
    dirName: name,
    dir: '/skills/${source.name}/$name',
    source: source,
    projectId: projectId,
    manifest: c.manifest,
    report: c.report,
    digest: digest,
  );
}

void main() {
  group('front matter', () {
    test('reads plain, quoted and nested values', () {
      final fm = parseFrontMatter(_valid);
      expect(fm.fields['name'], 'make-deck');
      expect(fm.fields['license'], 'Apache-2.0');
      expect(fm.fields['metadata'], {'version': '1.0', 'author': 'someone'});
      expect(fm.body, startsWith('# Make a deck'));
    });

    test('reads folded and literal blocks and continued plain lines', () {
      final fm = parseFrontMatter(
        '---\nname: a\ndescription: >\n  First line\n  second line.\n\n  New paragraph.\n'
        'compatibility: |\n  needs git\n  needs node\nlicense: MIT and\n  more words\n---\nbody',
      );
      expect(fm.fields['description'], 'First line second line.\nNew paragraph.');
      expect(fm.fields['compatibility'], 'needs git\nneeds node');
      expect(fm.fields['license'], 'MIT and more words');
    });

    test('quotes, escapes and comments', () {
      final fm = parseFrontMatter(
        '---\nname: "a-b" # the name\ndescription: \'It\'\'s: fine\'\nlicense: MIT # c\n---\n',
      );
      expect(fm.fields['name'], 'a-b');
      expect(fm.fields['description'], "It's: fine");
      expect(fm.fields['license'], 'MIT');
    });

    test('refuses what it cannot read', () {
      expect(() => parseFrontMatter('# no front matter'), throwsFormatException);
      expect(() => parseFrontMatter('---\nname: a\n'), throwsFormatException);
      expect(() => parseFrontMatter('---\nname: a\nname: b\n---\n'), throwsFormatException);
      expect(() => parseFrontMatter('---\nallowed-tools: [a, b]\n---\n'), throwsFormatException);
      expect(() => parseFrontMatter('---\njust text\n---\n'), throwsFormatException);
      expect(() => parseFrontMatter('---\nname: "open\n---\n'), throwsFormatException);
    });
  });

  group('strict check', () {
    test('a valid skill passes with its manifest', () {
      final c = _check(_valid);
      expect(c.report.errors, isEmpty);
      expect(c.manifest!.name, 'make-deck');
      expect(c.manifest!.metadata['version'], '1.0');
      expect(c.report.hasScripts, isFalse);
    });

    test('name rules', () {
      expect(skillNameProblems('ok-name-2'), isEmpty);
      expect(skillNameProblems('Bad'), isNotEmpty);
      expect(skillNameProblems('-a'), isNotEmpty);
      expect(skillNameProblems('a-'), isNotEmpty);
      expect(skillNameProblems('a--b'), isNotEmpty);
      expect(skillNameProblems('a_b'), isNotEmpty);
      expect(skillNameProblems('a' * 65), isNotEmpty);
      expect(skillNameProblems('café'), isEmpty);
    });

    test('folder name and extra fields: errors on import, warnings on load', () {
      const md = '---\nname: make-deck\ndescription: d\nwhen_to_use: x\n---\nbody';
      final strict = _check(md, dir: 'other');
      expect(strict.report.errors, hasLength(2));
      final lenient = _check(md, dir: 'other', strict: false);
      expect(lenient.report.errors, isEmpty);
      expect(lenient.report.warnings, hasLength(2));
      expect(lenient.manifest!.extraFields, ['when_to_use']);
    });

    test('description and compatibility limits', () {
      String md(String extra) => '---\nname: make-deck\n$extra\n---\nbody';
      expect(_check(md('license: MIT')).report.errors.single, contains('needs a description'));
      expect(_check(md('description: ${'x' * 1025}')).report.ok, isFalse);
      expect(_check(md('description: use <system> tags')).report.ok, isFalse);
      expect(_check(md('description: 2 < 3')).report.ok, isTrue);
      expect(_check(md('description: d\ncompatibility: ${'x' * 501}')).report.ok, isFalse);
      expect(_check(md('description: d\nmetadata: plain')).report.ok, isFalse);
    });

    test('files: links, escapes, compiled programs and size caps', () {
      List<String> errors(List<SkillEntry> extra) => _check(
        _valid,
        entries: [
          SkillEntry('SKILL.md', size: _valid.length),
          ...extra,
        ],
      ).report.errors;
      expect(errors([const SkillEntry('scripts/run', kind: SkillEntryKind.link)]), isNotEmpty);
      expect(errors([const SkillEntry('../evil.sh', size: 1)]), isNotEmpty);
      expect(
        errors([
          const SkillEntry('bin/tool', size: 9, head: [0x7F, 0x45, 0x4C, 0x46]),
        ]),
        isNotEmpty,
      );
      expect(
        errors([
          const SkillEntry('a.exe', size: 9, head: [0x4D, 0x5A, 0, 0]),
        ]),
        isNotEmpty,
      );
      expect(errors([const SkillEntry('big.bin', size: SkillRules.maxFileBytes + 1)]), isNotEmpty);
      expect(errors([for (var i = 0; i <= SkillRules.maxFiles; i++) SkillEntry('r/$i.md', size: 1)]), isNotEmpty);
      expect(errors([const SkillEntry('a/b/c/d/e/f/g.md', size: 1)]), isNotEmpty);
      // Clutter is skipped, not reported.
      expect(errors([const SkillEntry('.DS_Store', size: 1), const SkillEntry('__MACOSX/x', size: 1)]), isEmpty);
    });

    test('scripts are flagged, hidden files and inline commands warned', () {
      final c = _check(
        '$_valid\nRun !`git status` first.',
        entries: [
          SkillEntry('SKILL.md', size: _valid.length),
          const SkillEntry('scripts/build.py', size: 10),
          const SkillEntry('.env', size: 10),
        ],
      );
      expect(c.report.ok, isTrue);
      expect(c.report.hasScripts, isTrue);
      expect(c.report.warnings.join(), allOf(contains('.env'), contains('!`command`')));
    });

    test('a missing or oversized SKILL.md is an error', () {
      expect(checkSkill(dirName: 'a', skillMd: null, entries: const []).report.ok, isFalse);
      expect(_check('x' * (SkillRules.maxSkillMdBytes + 1)).report.ok, isFalse);
    });
  });

  group('inline commands', () {
    test('escapes commands outside code and keeps code as is', () {
      const body = 'Now !`rm -rf /` and `!`inline``\n```\n!`fenced`\n```\nAlready \\!`kept`';
      final out = escapeInlineCommands(body);
      expect(out, contains(r'\!`rm -rf /`'));
      expect(out, contains('```\n!`fenced`\n```'));
      expect(out, contains(r'Already \!`kept`'));
      expect(hasInlineCommands(out), isFalse);
      expect(hasInlineCommands(body), isTrue);
      expect(escapeInlineCommands(out), out);
    });
  });

  group('settings and session skills', () {
    test('project skills need trust for the content on disk', () {
      final p = _installed('deploy', source: SkillSource.project, projectId: 'p1');
      var s = const SkillSettings();
      expect(s.active(p), isFalse);
      expect(skillStatus(p, s), contains('Came with the project'));
      s = s.withTrust(p.key, p.digest);
      expect(s.active(p), isTrue);
      final changed = _installed('deploy', source: SkillSource.project, projectId: 'p1', digest: 'd2');
      expect(s.active(changed), isFalse);
      expect(s.changedSinceTrusted(changed), isTrue);
      expect(skillStatus(changed, s), contains('Changed'));
    });

    test('library skills are on until turned off', () {
      final l = _installed('a');
      var s = const SkillSettings();
      expect(s.active(l), isTrue);
      s = s.withEnabled(l.key, false);
      expect(s.active(l), isFalse);
      expect(skillStatus(l, s), 'Off');
      expect(SkillSettings.fromJson(jsonDecode(jsonEncode(s.toJson()))).disabled, {l.key});
    });

    test('sorted, project wins by name, other projects left out', () {
      final lib = _installed('b-skill');
      final shared = _installed('b-skill', source: SkillSource.shared);
      final proj = _installed('b-skill', source: SkillSource.project, projectId: 'p1');
      final other = _installed('c-skill', source: SkillSource.project, projectId: 'p2');
      final a = _installed('a-skill', source: SkillSource.shared);
      final settings = const SkillSettings().withTrust(proj.key, proj.digest).withTrust(other.key, other.digest);
      final all = [lib, shared, proj, other, a];
      expect([for (final s in sessionSkills(all, settings, 'p1')) s.key], ['shared:a-skill', proj.key]);
      expect([for (final s in sessionSkills(all, settings, null)) s.key], ['shared:a-skill', 'library:b-skill']);
      // An untrusted project skill can't hide the user's own skill of that name.
      expect(
        [for (final s in sessionSkills(all, const SkillSettings(), 'p1')) s.key],
        ['shared:a-skill', 'library:b-skill'],
      );
      // In Settings the untrusted project skill is listed as itself, not hidden.
      expect(winnersFor(all, 'p1')['b-skill']!.key, proj.key);
    });

    test('the OpenHands skill escapes inline commands and lists the file', () {
      final md = '---\nname: x\ndescription: d\nallowed-tools: Bash Read\n---\nDo !`whoami`.';
      final c = checkSkill(dirName: 'x', skillMd: md, entries: const [SkillEntry('SKILL.md', size: 1)]);
      final s = InstalledSkill(
        dirName: 'x',
        dir: '/lib/x',
        source: SkillSource.library,
        manifest: c.manifest,
        report: c.report,
        digest: '',
      );
      final json = openHandsSkill(s);
      expect(json['content'], r'Do \!`whoami`.');
      expect(json['source'], '/lib/x/SKILL.md');
      expect(json['is_agentskills_format'], isTrue);
      expect(json['trigger'], isNull);
      expect(json['allowed_tools'], ['Bash', 'Read']);
    });
  });

  test('invoke_skill is read-only and titled', () {
    final call = ActionCall(
      id: 'a',
      raw: const {},
      toolName: 'invoke_skill',
      toolCallId: 't',
      action: const {'kind': 'InvokeSkillAction', 'name': 'make-deck'},
    );
    expect(AgentMode.isReadOnly(call), isTrue);
    expect(AgentMode.plan.autoApproves(call), isTrue);
    expect(stepTitle(call), 'Loaded the make-deck skill');
  });

  group('import', () {
    List<SkillFile> zip(Map<String, String> files) {
      final a = Archive();
      files.forEach((k, v) => a.addFile(ArchiveFile.bytes(k, utf8.encode(v))));
      return zipFiles(Uint8List.fromList(ZipEncoder().encode(a)));
    }

    test('a SKILL.md at the top of a zip takes the skill name', () async {
      final c = await findImportCandidates(zip({'SKILL.md': _valid, 'references/a.md': 'x'}), fallbackName: 'z');
      expect(c.single.dirName, 'make-deck');
      expect(c.single.ok, isTrue);
      expect([for (final f in c.single.files) f.path], containsAll(['SKILL.md', 'references/a.md']));
    });

    test('a collection yields each skill; nested skills stay inside', () async {
      final other = _valid.replaceAll('make-deck', 'other');
      final c = await findImportCandidates(
        zip({
          'pack/README.md': 'ignored',
          'pack/make-deck/SKILL.md': _valid,
          'pack/make-deck/inner/SKILL.md': other,
          'pack/other/SKILL.md': other,
        }),
        fallbackName: 'pack',
      );
      expect([for (final x in c) x.dirName], ['make-deck', 'other']);
      expect([for (final f in c.first.files) f.path], contains('inner/SKILL.md'));
      expect(c.every((x) => x.ok), isTrue);
    });

    test('zip heads stop inflating early; full reads keep no cached copy', () async {
      final big = Uint8List(2 * 1024 * 1024)..setAll(0, [0x7f, 0x45, 0x4c, 0x46]);
      final a = Archive()
        ..addFile(ArchiveFile.bytes('SKILL.md', utf8.encode(_valid)))
        ..addFile(ArchiveFile.bytes('tool', big));
      final files = zipFiles(Uint8List.fromList(ZipEncoder().encode(a)));
      final tool = files.firstWhere((f) => f.path == 'tool');
      expect(await tool.readHead!(), [0x7f, 0x45, 0x4c, 0x46]);
      expect((await tool.read!()).length, big.length);
      final c = await findImportCandidates(files, fallbackName: 'z');
      expect(c.single.check.report.errors.join(), contains('compiled programs'));
    });

    test('past the file or size limits no file but SKILL.md is read', () async {
      Never boom() => throw StateError('read');
      final md = utf8.encode(_valid);
      final many = [
        SkillFile('SKILL.md', size: md.length, read: () async => Uint8List.fromList(md)),
        for (var i = 0; i < SkillRules.maxFiles + 1; i++)
          SkillFile('f$i.txt', size: 10, read: () async => boom(), readHead: () async => boom()),
      ];
      final c = await findImportCandidates(many, fallbackName: 'make-deck');
      expect(c.single.check.report.errors, contains('More than ${SkillRules.maxFiles} files.'));
      final huge = [
        many.first,
        for (var i = 0; i < 4; i++) SkillFile('f$i.bin', size: SkillRules.maxFileBytes, read: () async => boom()),
      ];
      final h = await findImportCandidates(huge, fallbackName: 'make-deck');
      expect(h.single.ok, isFalse);
    });

    test('a skill learned in chat goes through the strict check into the library', () async {
      final recorder = _RecordingSkills();
      final c = ProviderContainer(overrides: [installedSkillsProvider.overrideWith(() => recorder)]);
      addTearDown(c.dispose);
      final save = c.read(skillSaverProvider);
      final saved = await save(
        const SkillMd(name: 'make-deck', description: 'Plan a deck. Use it for slides.', body: 'Do it.'),
      );
      expect(saved.name, 'make-deck');
      expect(recorder.imported.single.dirName, 'make-deck');
      await expectLater(
        save(const SkillMd(name: 'bad', description: 'Has <b>tags</b> in it.', body: 'x')),
        throwsStateError,
      );
      expect(recorder.imported, hasLength(1));
    });

    test('a mismatched folder name is refused on import', () async {
      final c = await findImportCandidates(zip({'wrong/SKILL.md': _valid}), fallbackName: 'z');
      expect(c.single.ok, isFalse);
    });
  });

  group('on disk', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('skills_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('import a folder, scan it, digest changes with content, remove it', () async {
      final src = Directory('${tmp.path}/src/make-deck')..createSync(recursive: true);
      File('${src.path}/SKILL.md').writeAsStringSync(_valid);
      Directory('${src.path}/scripts').createSync();
      File('${src.path}/scripts/run.sh').writeAsStringSync('echo hi');
      final candidates = await findImportCandidates(await store.folderFiles(src.path), fallbackName: 'make-deck');
      expect(candidates.single.ok, isTrue);
      final lib = '${tmp.path}/lib';
      final dir = await store.install(candidates.single, lib);
      expect(File('$dir/scripts/run.sh').readAsStringSync(), 'echo hi');
      await expectLater(store.install(candidates.single, lib), throwsStateError);

      final project = Directory('${tmp.path}/proj/.agents/skills/make-deck')..createSync(recursive: true);
      File('${project.path}/SKILL.md').writeAsStringSync(_valid);
      final roots = (library: lib, shared: '${tmp.path}/none', projects: [(id: 'p', path: '${tmp.path}/proj')]);
      final found = await store.scan(roots);
      expect([for (final s in found) s.key], ['library:make-deck', 'project:p:make-deck']);
      final installed = found.first;
      expect(installed.usable, isTrue);
      expect(installed.report.hasScripts, isTrue);
      expect(installed.digest, isNotEmpty);

      File('$dir/scripts/run.sh').writeAsStringSync('echo changed');
      final again = (await store.scan(roots)).first;
      expect(again.digest, isNot(installed.digest));

      await store.delete(dir);
      expect(Directory(dir).existsSync(), isFalse);
    });

    test('a project skill with too many entries is refused whole and has no digest to trust', () async {
      final skill = Directory('${tmp.path}/proj/.agents/skills/make-deck')..createSync(recursive: true);
      File('${skill.path}/SKILL.md').writeAsStringSync(_valid);
      for (var i = 0; i < SkillRules.maxFiles * 2; i++) {
        Directory('${skill.path}/d$i').createSync();
      }
      final found = await store.scan((library: null, shared: null, projects: [(id: 'p', path: '${tmp.path}/proj')]));
      final s = found.single;
      expect(s.usable, isFalse);
      expect(s.report.errors.join(), contains('files and folders'));
      expect(s.digest, isEmpty);
      expect(const SkillSettings().withTrust(s.key, s.digest).trustedNow(s), isFalse);
    });

    test('a project skill folder that is a link is skipped', () async {
      final real = Directory('${tmp.path}/real/x')..createSync(recursive: true);
      File('${real.path}/SKILL.md').writeAsStringSync(_valid.replaceAll('make-deck', 'x'));
      Directory('${tmp.path}/proj/.agents/skills').createSync(recursive: true);
      Link('${tmp.path}/proj/.agents/skills/x').createSync(real.path);
      Directory('${tmp.path}/shared').createSync();
      Link('${tmp.path}/shared/x').createSync(real.path);
      final found = await store.scan((
        library: null,
        shared: '${tmp.path}/shared',
        projects: [(id: 'p', path: '${tmp.path}/proj')],
      ));
      expect([for (final s in found) s.key], ['shared:x']);
      await store.delete(found.single.dir);
      expect(Directory(real.path).existsSync(), isTrue);
    });
  });
}

final class _RecordingSkills extends NoInstalledSkills {
  final imported = <ImportCandidate>[];

  @override
  Future<InstalledSkill?> import(ImportCandidate c, {String? projectId, String? projectPath}) async {
    imported.add(c);
    return null;
  }
}
