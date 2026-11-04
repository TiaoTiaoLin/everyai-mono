import 'dart:convert';
import 'dart:io';

import '../../../skills/data/skill_store_io.dart' show digestOfBytes;
import '../../../skills/domain/skill_catalog.dart';
import '../../../skills/domain/skill_format.dart';
import 'briefing_types.dart';
import 'skill_export.dart' show ExportResult;
import 'skill_render.dart';

const _pluginJson = {'name': everyaiServerName, 'description': 'Skills and rules for this EveryAI session.'};

/// A file to have in the briefing. Copies are read into memory once, so what was checked is what is written.
class _Want {
  _Want(this.bytes, {this.exec = false});
  final List<int> bytes;
  final bool exec;
}

Future<ExportResult> exportSkills(String sessionDir, List<InstalledSkill> skills, String sessionText) async {
  final root = '$sessionDir/briefing';
  final skillDir = '$root/skills';
  final skipped = <String>[];
  final names = <String>[];
  // Relative to root; '/'-separated.
  final want = <String, _Want>{
    '.claude-plugin/plugin.json': _Want(utf8.encode('${jsonEncode(_pluginJson)}\n')),
    sessionFileName: _Want(utf8.encode(sessionText)),
  };

  for (final s in skills) {
    final m = s.manifest;
    if (m == null || !s.usable) {
      skipped.add('${s.dirName}: not a valid skill');
    } else if (m.metadata.containsKey('tool')) {
      skipped.add('${m.name}: needs a chat tool');
    } else if (skillNameProblems(m.name).isNotEmpty || names.contains(m.name)) {
      skipped.add('${m.name}: name not usable here');
    } else {
      final dir = await _resolve(s.dir);
      final copies = <String, _Want>{};
      var dropped = false;
      for (final rel in s.files) {
        final p = await _sourceProblem(s.dir, dir, rel);
        if (p != null) {
          skipped.add('${m.name}/$rel: $p');
          dropped = true;
        } else {
          copies[rel] = _Want(await File('${s.dir}/$rel').readAsBytes(), exec: _executable('${s.dir}/$rel'));
        }
      }
      // A project skill was trusted at one digest: its files must still be exactly those.
      if (s.source == SkillSource.project) {
        final md = File('${s.dir}/SKILL.md');
        final all = <(String, List<int>)>[
          ('SKILL.md', await md.exists() ? await md.readAsBytes() : const []),
          for (final e in copies.entries) (e.key, e.value.bytes),
        ];
        if (s.digest.isEmpty || dropped || digestOfBytes(all) != s.digest) {
          skipped.add('${m.name}: changed since it was trusted');
          continue;
        }
      }
      names.add(m.name);
      final base = 'skills/${m.name}';
      want['$base/SKILL.md'] = _Want(utf8.encode(renderSkillMd(m)));
      for (final e in copies.entries) {
        want['$base/${e.key}'] = e.value;
      }
    }
  }

  await Directory(sessionDir).create(recursive: true);
  await _prepareRoot(root);
  var written = 0;
  for (final e in want.entries) {
    if (await _put(root, e.key, e.value)) written++;
  }
  written += await _prune(skillDir, {
    for (final k in want.keys)
      if (k.startsWith('skills/')) k.substring(7),
  });
  return (skillDir: skillDir, names: names..sort(), written: written, skipped: skipped);
}

Future<void> removeBriefing(String sessionDir) async {
  final root = '$sessionDir/briefing';
  switch (FileSystemEntity.typeSync(root, followLinks: false)) {
    case FileSystemEntityType.link:
      await Link(root).delete();
    case FileSystemEntityType.directory:
      await Directory(root).delete(recursive: true);
    case FileSystemEntityType.file:
      await File(root).delete();
    default:
  }
}

/// The briefing folder itself must be a real directory (or absent): a link there could point anywhere.
Future<void> _prepareRoot(String root) async {
  switch (FileSystemEntity.typeSync(root, followLinks: false)) {
    case FileSystemEntityType.link:
      throw StateError('Refusing to export: $root is a link.');
    case FileSystemEntityType.notFound:
      await Directory(root).create();
    case FileSystemEntityType.directory:
      break;
    default:
      throw StateError('Refusing to export: $root is not a folder.');
  }
}

Future<String> _resolve(String path) async {
  try {
    return await Directory(path).resolveSymbolicLinks();
  } on FileSystemException {
    return path;
  }
}

/// Why the skill file [rel] must not be copied; null when it may.
Future<String?> _sourceProblem(String skillDir, String resolvedDir, String rel) async {
  final parts = rel.split('/');
  if (rel.startsWith('/') || rel.contains('\\') || parts.any((p) => p.isEmpty || p == '.' || p == '..')) {
    return 'path leaves the skill folder';
  }
  final path = '$skillDir/$rel';
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return 'not a plain file';
  try {
    final real = await File(path).resolveSymbolicLinks();
    if (!real.startsWith('$resolvedDir/')) return 'resolves outside the skill folder';
  } on FileSystemException {
    return 'unreadable';
  }
  if (await File(path).length() > SkillRules.maxFileBytes) return 'too large';
  return null;
}

/// Makes every folder on the way to [rel] a real one, replacing a link or file found in the way.
Future<void> _ensureParents(String root, String rel) async {
  final parts = rel.split('/')..removeLast();
  var path = root;
  for (final p in parts) {
    path = '$path/$p';
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.directory:
        continue;
      case FileSystemEntityType.link:
        await Link(path).delete();
      case FileSystemEntityType.file:
        await File(path).delete();
      default:
    }
    await Directory(path).create();
  }
}

bool _executable(String path) => Platform.isWindows ? false : (File(path).statSync().mode & 0x49) != 0;

/// Writes one file if it differs; true when it did. A temp file in the same folder is renamed over the target, so a
/// link at the target is replaced rather than written through.
Future<bool> _put(String root, String rel, _Want w) async {
  final path = '$root/$rel';
  await _ensureParents(root, rel);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.file && await _same(path, w)) return false;
  if (type == FileSystemEntityType.directory) await Directory(path).delete(recursive: true);
  final tmp = '$path.everyai-tmp';
  if (FileSystemEntity.typeSync(tmp, followLinks: false) != FileSystemEntityType.notFound) {
    await _removeAny(tmp);
  }
  await File(tmp).writeAsBytes(w.bytes);
  if (w.exec) await Process.run('chmod', ['+x', tmp]);
  await File(tmp).rename(path);
  return true;
}

Future<bool> _same(String path, _Want w) async {
  final a = await File(path).readAsBytes();
  final b = w.bytes;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return !w.exec || _executable(path);
}

Future<void> _removeAny(String path) async {
  switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    case FileSystemEntityType.link:
      await Link(path).delete();
    case FileSystemEntityType.directory:
      await Directory(path).delete(recursive: true);
    case FileSystemEntityType.notFound:
      break;
    default:
      await File(path).delete();
  }
}

/// Deletes what is under [skillsDir] and not in [keep] (paths relative to it). Returns how many were removed.
Future<int> _prune(String skillsDir, Set<String> keep) async {
  if (FileSystemEntity.typeSync(skillsDir, followLinks: false) != FileSystemEntityType.directory) return 0;
  final folders = {
    for (final k in keep)
      for (var i = k.indexOf('/'); i >= 0; i = k.indexOf('/', i + 1)) k.substring(0, i),
  };
  var removed = 0;
  final entries = await Directory(skillsDir).list(recursive: true, followLinks: false).toList();
  // Deepest first, so a folder is looked at after what is in it.
  entries.sort((a, b) => b.path.length.compareTo(a.path.length));
  for (final e in entries) {
    final rel = e.path.substring(skillsDir.length + 1);
    if (keep.contains(rel) || folders.contains(rel)) continue;
    if (FileSystemEntity.typeSync(e.path, followLinks: false) == FileSystemEntityType.notFound) continue;
    await _removeAny(e.path);
    removed++;
  }
  return removed;
}
