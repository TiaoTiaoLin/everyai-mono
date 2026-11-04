import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/drivers/briefing/skill_export.dart';
import 'package:every_ai/features/code/drivers/briefing/skill_render.dart';
import 'package:every_ai/features/skills/domain/skill_catalog.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:flutter_test/flutter_test.dart';

import '_fixtures.dart';

void main() {
  late Directory tmp;
  late Directory src;
  late String session;
  const sessionMd = '---\nname: everyai-session\ndescription: "x"\n---\n\nhello\n';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('briefing_export_');
    src = Directory('${tmp.path}/skills-src')..createSync();
    session = '${tmp.path}/session';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String read(String rel) => File('$session/briefing/$rel').readAsStringSync();

  test('writes only the skills the caller passes, never chat-only ones', () async {
    final a = writeSkill(src, 'alpha');
    final b = writeSkill(src, 'beta');
    final chat = writeSkill(src, 'chat-only', front: 'metadata:\n  tool: render_svg\n');
    // The caller applies the settings: disabled and untrusted skills never reach the exporter.
    final settings = SkillSettings(disabled: {b.key});
    final project = writeSkill(src, 'repo-skill', source: SkillSource.project, projectId: 'p', body: 'x');
    final active = sessionSkills([a, b, chat, project], settings, 'p');
    expect(active.map((s) => s.name), ['alpha', 'chat-only']);
    final r = await exportSkills(session, active, sessionSkillMd: sessionMd);
    expect(r.names, ['alpha']);
    expect(r.skipped.single, startsWith('chat-only'));
    expect(Directory(r.skillDir).listSync().map((e) => e.path.split('/').last).toList()..sort(), [
      'alpha',
      'everyai-session',
    ]);
    expect(read('skills/everyai-session/SKILL.md'), sessionMd);
  });

  test('SKILL.md round-trips, drops allowed-tools, escapes commands', () async {
    final s = writeSkill(
      src,
      'alpha',
      front: 'license: MIT\nallowed-tools: Bash(rm:*)\nmetadata:\n  version: "1.0"\n',
      body: 'Run !`rm -rf x` now.\n\n```!\nls\n```\n\n~~~!\nid\n~~~\n\nKeep `plain code`.',
    );
    await exportSkills(session, [s], sessionSkillMd: sessionMd);
    final md = read('skills/alpha/SKILL.md');
    final fm = parseFrontMatter(md);
    expect(fm.fields['name'], 'alpha');
    expect(fm.fields['license'], 'MIT');
    expect(fm.fields['metadata'], {'version': '1.0'});
    expect(fm.fields.containsKey('allowed-tools'), isFalse);
    expect(md, isNot(contains('allowed-tools')));
    expect(md, contains(r'\!`rm -rf x`'));
    expect(md, isNot(contains('```!')));
    expect(md, isNot(contains('~~~!')));
    expect(md, contains('``` !'));
    expect(md, contains('Keep `plain code`.'));
    expect(hasInlineCommands(fm.body), isFalse);
  });

  test('descriptions with quotes and backslashes survive', () {
    const m = SkillManifest(name: 'q', description: 'Say "hi" \\ and\nmore.', body: 'b');
    expect(parseFrontMatter(renderSkillMd(m)).fields['description'], 'Say "hi" \\ and\nmore.');
  });

  test('supporting files are copied byte for byte, exec bit kept', () async {
    final s = writeSkill(src, 'alpha', files: {'references/a.md': 'ref', 'scripts/run.sh': '#!/bin/sh\necho hi\n'});
    if (!Platform.isWindows) Process.runSync('chmod', ['+x', '${s.dir}/scripts/run.sh']);
    await exportSkills(session, [s], sessionSkillMd: sessionMd);
    expect(read('skills/alpha/references/a.md'), 'ref');
    final out = File('$session/briefing/skills/alpha/scripts/run.sh');
    expect(out.readAsBytesSync(), File('${s.dir}/scripts/run.sh').readAsBytesSync());
    if (!Platform.isWindows) expect(out.statSync().mode & 0x49, isNot(0));
    expect(File('$session/briefing/skills/alpha/references/a.md').statSync().mode & 0x49, 0);
  });

  test('plugin.json is valid and names the plugin', () async {
    await exportSkills(session, const [], sessionSkillMd: sessionMd);
    final j = jsonDecode(read('.claude-plugin/plugin.json')) as Map;
    expect(j['name'], 'everyai');
  });

  test('a second run writes nothing; a removed skill takes only its own folder', () async {
    final a = writeSkill(src, 'alpha', files: {'references/a.md': 'ref'});
    final b = writeSkill(src, 'beta');
    final first = await exportSkills(session, [a, b], sessionSkillMd: sessionMd);
    expect(first.written, greaterThan(0));
    final again = await exportSkills(session, [a, b], sessionSkillMd: sessionMd);
    expect(again.written, 0);
    // A stray file and a changed session text.
    File('$session/briefing/skills/beta/old.txt').writeAsStringSync('stale');
    final dropped = await exportSkills(session, [a], sessionSkillMd: sessionMd);
    expect(Directory('$session/briefing/skills/beta').existsSync(), isFalse);
    expect(File('$session/briefing/skills/alpha/references/a.md').existsSync(), isTrue);
    expect(dropped.written, greaterThan(0));
    final third = await exportSkills(session, [a], sessionSkillMd: sessionMd);
    expect(third.written, 0);
    // Changed source content is picked up.
    File('${a.dir}/references/a.md').writeAsStringSync('new');
    expect((await exportSkills(session, [a], sessionSkillMd: sessionMd)).written, 1);
    expect(read('skills/alpha/references/a.md'), 'new');
  });

  test('removeBriefing leaves siblings', () async {
    final a = writeSkill(src, 'alpha');
    await exportSkills(session, [a], sessionSkillMd: sessionMd);
    File('$session/state.json').writeAsStringSync('{}');
    await removeBriefing(session);
    expect(Directory('$session/briefing').existsSync(), isFalse);
    expect(File('$session/state.json').existsSync(), isTrue);
    await removeBriefing(session); // nothing there: fine
  });
}
