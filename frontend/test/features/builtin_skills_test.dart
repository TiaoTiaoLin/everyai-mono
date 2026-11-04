import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/skills/data/skill_store_io.dart' as store;
import 'package:every_ai/features/skills/domain/builtin_skills.dart';
import 'package:every_ai/features/skills/domain/skill_catalog.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled skills pass the strict validator', () async {
    final skills = await loadBuiltinSkills();
    expect(skills.map((s) => s.name), ['draw-diagram', 'everyai-max', 'make-deck', 'vector-art', 'write-artifact']);
    for (final s in skills) {
      final md = utf8.decode(s.files['SKILL.md']!);
      final check = checkSkill(
        dirName: s.name,
        skillMd: md,
        entries: [
          for (final e in s.files.entries) SkillEntry(e.key, size: e.value.length, head: e.value.take(4).toList()),
        ],
      );
      expect(check.report.errors, isEmpty, reason: s.name);
      expect(check.report.warnings, isEmpty, reason: s.name);
      expect(check.manifest!.name, s.name);
      expect(check.manifest!.license, 'Apache-2.0');
      expect(check.report.hasScripts, isFalse);
      expect(s.files.keys, contains('LICENSE.txt'));
      expect(utf8.decode(s.files['LICENSE.txt']!), contains('Apache License'));
      expect(md.split('\n').length, lessThan(SkillRules.longBodyLines));
    }
  });

  test('the Max approach skill goes to outside harnesses and is Code-only in Chat', () async {
    final max = (await loadBuiltinSkills()).singleWhere((s) => s.name == 'everyai-max');
    final m = checkSkill(dirName: max.name, skillMd: utf8.decode(max.files['SKILL.md']!), entries: const []).manifest!;
    // No metadata.tool: the briefing export ships it (tool skills are Chat's).
    expect(m.metadata['tool'], isNull);
    for (final tool in ['ask_user_question', 'present_plan', 'fork', 'check_forks', 'answer_fork', 'stop_fork']) {
      expect(m.body, contains('`$tool`'), reason: tool);
    }
    expect(m.body, contains('run_subagent'));
  });

  test('seeding installs once, respects removal and updates on a new digest', () async {
    final skills = await loadBuiltinSkills();
    final lib = await Directory.systemTemp.createTemp('builtin-skills');
    addTearDown(() => lib.delete(recursive: true));
    final dir = '${lib.path}/skills';

    await store.seedBuiltins(dir, skills);
    expect(File('$dir/make-deck/SKILL.md').existsSync(), isTrue);
    final scanned = await store.scan((library: dir, shared: null, projects: const []));
    expect(scanned.where((s) => s.usable && s.source == SkillSource.library), hasLength(5));

    // Removed by the user: stays removed.
    await store.delete('$dir/make-deck');
    await store.seedBuiltins(dir, skills);
    expect(Directory('$dir/make-deck').existsSync(), isFalse);

    // An app update ships a changed copy: it replaces the old one.
    final changed = BuiltinSkill('vector-art', {
      ...skills.firstWhere((s) => s.name == 'vector-art').files,
      'SKILL.md': utf8.encode('---\nname: vector-art\ndescription: New.\n---\nBody.\n'),
    });
    await store.seedBuiltins(dir, [changed]);
    expect(File('$dir/vector-art/SKILL.md').readAsStringSync(), contains('New.'));

    // Removed, then updated by the app: still removed.
    BuiltinSkill bumped(String name, String text) => BuiltinSkill(name, {
      ...skills.firstWhere((s) => s.name == name).files,
      'SKILL.md': utf8.encode('---\nname: $name\ndescription: $text\n---\nBody.\n'),
    });
    await store.seedBuiltins(dir, [bumped('make-deck', 'Newer.')]);
    expect(Directory('$dir/make-deck').existsSync(), isFalse);

    // Edited by the user, then updated by the app: the edit stays.
    File('$dir/draw-diagram/SKILL.md').writeAsStringSync('my edit');
    await store.seedBuiltins(dir, [bumped('draw-diagram', 'Newer.')]);
    expect(File('$dir/draw-diagram/SKILL.md').readAsStringSync(), 'my edit');

    // A folder the user made with a bundled name is never overwritten.
    final other = await Directory.systemTemp.createTemp('own-skills');
    addTearDown(() => other.delete(recursive: true));
    await Directory('${other.path}/make-deck').create();
    await File('${other.path}/make-deck/SKILL.md').writeAsString('mine');
    await store.seedBuiltins(other.path, skills);
    expect(File('${other.path}/make-deck/SKILL.md').readAsStringSync(), 'mine');
  });
}
