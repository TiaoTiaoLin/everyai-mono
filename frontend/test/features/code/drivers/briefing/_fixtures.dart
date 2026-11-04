import 'dart:io';

import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart';
import 'package:every_ai/features/skills/domain/skill_catalog.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';

BriefingInput input({String token = 'tok-SECRET-123', String root = '/data/s1/briefing'}) => (
  mcpUrl: Uri.parse('http://127.0.0.1:5123/mcp'),
  mcpToken: token,
  skillDir: '$root/skills',
  sessionText: '# Session\n\nBody text.\n',
);

/// Writes a skill folder under [parent] and returns it as the scanner would.
InstalledSkill writeSkill(
  Directory parent,
  String name, {
  String front = '',
  String body = 'Do the thing.',
  Map<String, String> files = const {},
  SkillSource source = SkillSource.library,
  String? projectId,
}) {
  final dir = Directory('${parent.path}/$name')..createSync(recursive: true);
  final md = '---\nname: $name\ndescription: Does $name. Use it when asked.\n$front---\n$body\n';
  File('${dir.path}/SKILL.md').writeAsStringSync(md);
  for (final e in files.entries) {
    File('${dir.path}/${e.key}')
      ..createSync(recursive: true)
      ..writeAsStringSync(e.value);
  }
  final c = checkSkill(dirName: name, skillMd: md, entries: const [SkillEntry('SKILL.md', size: 10)], strict: false);
  return InstalledSkill(
    dirName: name,
    dir: dir.path,
    source: source,
    projectId: projectId,
    manifest: c.manifest,
    report: c.report,
    digest: 'd',
    files: [...files.keys]..sort(),
  );
}
