import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/builtin_skills.dart';
import '../domain/skill_catalog.dart';
import '../domain/skill_format.dart';
import 'skill_import.dart';
import 'skill_store.dart' show SkillRoots;

const _projectDir = '.agents/skills';

Future<SkillRoots> roots(List<({String id, String path})> projects) async {
  String? library;
  try {
    library = '${(await getApplicationSupportDirectory()).path}/skills';
  } on Object {
    library = null;
  }
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  return (library: library, shared: home == null ? null : '$home/.agents/skills', projects: projects);
}

Future<List<InstalledSkill>> scan(SkillRoots roots) async {
  final out = <InstalledSkill>[];
  if (roots.library case final dir?) out.addAll(await _scanRoot(dir, SkillSource.library));
  if (roots.shared case final dir?) out.addAll(await _scanRoot(dir, SkillSource.shared));
  for (final p in roots.projects) {
    out.addAll(await _scanRoot('${p.path}/$_projectDir', SkillSource.project, projectId: p.id));
  }
  return out;
}

Future<List<InstalledSkill>> _scanRoot(String root, SkillSource source, {String? projectId}) async {
  final dir = Directory(root);
  if (!dir.existsSync()) return const [];
  final out = <InstalledSkill>[];
  try {
    final children = await dir.list(followLinks: false).toList();
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final e in children) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('.')) continue;
      final skillDir = e.path;
      if (e is Link) {
        // The user's own folders may link a skill in (removing it removes
        // the link only); a repository may not.
        if (source == SkillSource.project) continue;
        if (!FileSystemEntity.isDirectorySync(await e.resolveSymbolicLinks())) continue;
      } else if (e is! Directory) {
        continue;
      }
      if (!File('$skillDir/SKILL.md').existsSync()) continue;
      out.add(await _load(skillDir, name, source, projectId));
    }
  } on FileSystemException {
    return out;
  }
  return out;
}

Future<InstalledSkill> _load(String dir, String dirName, SkillSource source, String? projectId) async {
  final entries = <SkillEntry>[];
  final files = <(String, File)>[];
  var total = 0;
  var overflow = false;
  var unreadable = false;
  try {
    await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
      // Past this many entries the folder is refused whole: a digest over
      // part of it would let the rest change without anyone noticing.
      if (entries.length >= SkillRules.maxFiles * 2) {
        overflow = true;
        break;
      }
      final rel = e.path.substring(dir.length + 1).replaceAll('\\', '/');
      if (SkillRules.ignored(rel)) continue;
      final stat = await e.stat();
      final kind = switch (e) {
        Link() => SkillEntryKind.link,
        Directory() => SkillEntryKind.directory,
        File() => SkillEntryKind.file,
        _ => SkillEntryKind.other,
      };
      var head = const <int>[];
      if (e is File) {
        total += stat.size;
        files.add((rel, e));
        if (stat.size >= 2 && stat.size <= SkillRules.maxFileBytes) head = await _head(e);
      }
      entries.add(SkillEntry(rel, size: e is File ? stat.size : 0, kind: kind, head: head));
    }
  } on FileSystemException {
    // Not fully listed: checked, but a project copy can't be trusted (no digest).
    unreadable = true;
  }
  // SKILL.md is always hashed, wherever the listing put it.
  if (!files.any((f) => f.$1 == 'SKILL.md')) files.add(('SKILL.md', File('$dir/SKILL.md')));
  String? text;
  final md = File('$dir/SKILL.md');
  try {
    text = await md.length() > SkillRules.maxSkillMdBytes
        ? 'x' * (SkillRules.maxSkillMdBytes + 1)
        : utf8.decode(await md.readAsBytes(), allowMalformed: true);
  } on FileSystemException {
    text = null;
  }
  final check = checkSkill(dirName: dirName, skillMd: text, entries: entries, strict: false);
  final report = overflow
      ? SkillReport(
          errors: [...check.report.errors, 'More than ${SkillRules.maxFiles * 2} files and folders.'],
          warnings: check.report.warnings,
          hasScripts: check.report.hasScripts,
          findings: check.report.findings,
        )
      : check.report;
  return InstalledSkill(
    dirName: dirName,
    dir: dir,
    source: source,
    projectId: projectId,
    manifest: check.manifest,
    report: report,
    digest: overflow || unreadable || total > SkillRules.maxTotalBytes ? '' : await _digest(files),
    files: [
      for (final (rel, _) in files)
        if (rel != 'SKILL.md') rel,
    ]..sort(),
  );
}

Future<List<int>> _head(File f) async {
  final raf = await f.open();
  try {
    return await raf.read(4);
  } finally {
    await raf.close();
  }
}

/// SHA-256 over every file's path and bytes, in path order.
Future<String> _digest(List<(String, File)> files) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  final sorted = [...files]..sort((a, b) => a.$1.compareTo(b.$1));
  for (final (rel, f) in sorted) {
    input.add(utf8.encode('$rel\u0000'));
    try {
      await for (final chunk in f.openRead()) {
        input.add(chunk);
      }
    } on FileSystemException {
      input.add(utf8.encode('<unreadable>'));
    }
    input.add(const [0]);
  }
  input.close();
  return sink.value.toString();
}

/// The digest of files already in memory ([path] relative to the skill folder, bytes): the same hash as the scan's,
/// so a copy can be checked against the digest a skill was trusted at.
String digestOfBytes(Iterable<(String, List<int>)> files) {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  final sorted = [...files]..sort((a, b) => a.$1.compareTo(b.$1));
  for (final (rel, bytes) in sorted) {
    input
      ..add(utf8.encode('$rel\u0000'))
      ..add(bytes)
      ..add(const [0]);
  }
  input.close();
  return sink.value.toString();
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<List<SkillFile>> folderFiles(String path) async {
  final root = Directory(path);
  final name = root.uri.pathSegments.where((s) => s.isNotEmpty).last;
  final out = <SkillFile>[];
  // The chosen folder may be one skill or hold several: list it as if its
  // parent were the import root, so a SKILL.md at its top keeps its name.
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (out.length > SkillRules.maxFiles * 4) break;
    final rel = '$name/${e.path.substring(root.path.length).replaceAll('\\', '/').replaceFirst(RegExp('^/'), '')}';
    switch (e) {
      case Link():
        out.add(SkillFile(rel, size: 0, kind: SkillEntryKind.link));
      case Directory():
        out.add(SkillFile(rel, size: 0, kind: SkillEntryKind.directory));
      case File():
        out.add(SkillFile(rel, size: await e.length(), read: e.readAsBytes));
      default:
        out.add(SkillFile(rel, size: 0, kind: SkillEntryKind.other));
    }
  }
  return out;
}

Future<String> install(ImportCandidate candidate, String destDir) async {
  if (!candidate.ok) throw StateError(candidate.check.report.errors.first);
  final name = candidate.dirName;
  final target = Directory('$destDir/$name');
  if (target.existsSync() || Link(target.path).existsSync()) {
    throw StateError('A skill called "$name" is already in $destDir. Remove it first to replace it.');
  }
  final staging = Directory('$destDir/.importing-$name');
  if (staging.existsSync()) await staging.delete(recursive: true);
  await staging.create(recursive: true);
  try {
    for (final f in candidate.files) {
      if (SkillRules.ignored(f.path)) continue;
      final path = '${staging.path}/${f.path}';
      switch (f.kind) {
        case SkillEntryKind.directory:
          await Directory(path).create(recursive: true);
        case SkillEntryKind.file:
          final bytes = await (f.read?.call() ?? Future.value(Uint8List(0)));
          final file = File(path);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes, flush: true);
        case SkillEntryKind.link || SkillEntryKind.other:
          throw StateError('${f.path}: only plain files and folders can be imported.');
      }
    }
    await staging.rename(target.path);
  } on Object {
    if (staging.existsSync()) await staging.delete(recursive: true);
    rethrow;
  }
  return target.path;
}

Future<void> delete(String dir) async {
  final link = Link(dir);
  if (link.existsSync()) {
    await link.delete();
  } else if (Directory(dir).existsSync()) {
    await Directory(dir).delete(recursive: true);
  }
}

/// [rel]'s bytes inside skill folder [dir], or null when it is missing, a
/// link, larger than [maxBytes], or resolves outside the folder.
Future<List<int>?> readFile(String dir, String rel, int maxBytes) async {
  try {
    final root = await Directory(dir).resolveSymbolicLinks();
    final path = '$dir/$rel';
    if (FileSystemEntity.isLinkSync(path)) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    final real = await file.resolveSymbolicLinks();
    if (!real.startsWith('$root${Platform.pathSeparator}')) return null;
    if (await file.length() > maxBytes) return null;
    return await file.readAsBytes();
  } on FileSystemException {
    return null;
  }
}

/// The digest of the files under [dir], computed like [BuiltinSkill.digest].
Future<String> _folderDigest(String dir) async {
  final files = <(String, File)>[];
  await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(dir.length + 1).replaceAll('\\', '/');
    if (SkillRules.ignored(rel)) continue;
    files.add((rel, e));
  }
  return _digest(files);
}

/// Which version of each bundled skill was installed: `<library>/.builtin.json`.
/// A bundled skill is installed once; an app update replaces it only while
/// the user hasn't edited it, and one the user removed stays removed.
Future<void> seedBuiltins(String libraryDir, List<BuiltinSkill> skills) async {
  try {
    await Directory(libraryDir).create(recursive: true);
    final record = File('$libraryDir/.builtin.json');
    var seeded = <String, String>{};
    if (record.existsSync()) {
      try {
        final json = jsonDecode(await record.readAsString());
        if (json is Map) seeded = {for (final e in json.entries) '${e.key}': '${e.value}'};
      } on FormatException {
        seeded = {};
      }
    }
    var changed = false;
    for (final s in skills) {
      final recorded = seeded[s.name];
      if (recorded == s.digest) continue;
      final target = Directory('$libraryDir/${s.name}');
      final exists = target.existsSync() || Link(target.path).existsSync();
      // Installed before and gone now: the user removed it, so it stays removed.
      if (recorded != null && !exists) continue;
      // A folder we never installed is the user's own.
      if (exists && recorded == null) continue;
      // Ours, but edited since: the user's edits win over the update.
      if (exists && (Link(target.path).existsSync() || await _folderDigest(target.path) != recorded)) continue;
      final staging = Directory('$libraryDir/.seeding-${s.name}');
      if (staging.existsSync()) await staging.delete(recursive: true);
      for (final e in s.files.entries) {
        final f = File('${staging.path}/${e.key}');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(e.value, flush: true);
      }
      if (exists) await delete(target.path);
      await staging.rename(target.path);
      seeded[s.name] = s.digest;
      changed = true;
    }
    if (changed) await record.writeAsString(jsonEncode(seeded));
  } on FileSystemException {
    // Read-only or missing library: the bundled skills just don't appear.
  }
}
