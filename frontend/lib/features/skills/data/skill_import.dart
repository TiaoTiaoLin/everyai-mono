import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../domain/hidden_instructions.dart';
import '../domain/skill_format.dart';

/// A file offered for import, from a folder or a zip.
@immutable
final class SkillFile {
  const SkillFile(this.path, {required this.size, this.kind = SkillEntryKind.file, this.read, this.readHead});

  /// `/`-separated, relative to where the import started.
  final String path;
  final int size;
  final SkillEntryKind kind;

  /// The bytes (files only).
  final Future<Uint8List> Function()? read;

  /// The first few bytes without reading the rest, when the source can do
  /// that (a zip entry stops inflating early); else [read] is used.
  final Future<List<int>> Function()? readHead;

  /// The first 4 bytes, for the compiled-program check.
  Future<List<int>> head() async {
    if (readHead case final h?) {
      final bytes = await h();
      return bytes.length > 4 ? bytes.sublist(0, 4) : bytes;
    }
    final bytes = await read!();
    return bytes.length > 4 ? bytes.sublist(0, 4) : bytes;
  }
}

/// One skill found in an import: its folder name, the strict check, and its
/// files relative to the skill folder.
@immutable
final class ImportCandidate {
  const ImportCandidate({required this.dirName, required this.check, required this.files, this.findings = const []});

  final String dirName;
  final SkillCheck check;
  final List<SkillFile> files;

  /// Hidden or suspicious text in `SKILL.md` and the bundled text files: the user is asked before it is imported.
  final List<InstructionFinding> findings;
  bool get ok => check.report.ok;
}

/// Bundled files read for [scanInstructions]: text-like and at most this large.
const scannedFileBytes = 256 * 1024;

final _scannedName = RegExp(
  r'\.(md|markdown|txt|py|sh|bash|zsh|js|mjs|cjs|ts|rb|pl|ps1|json|ya?ml|html?|xml|toml)$',
  caseSensitive: false,
);

/// Whether a bundled file at [path] of [size] bytes is scanned for hidden instructions (`SKILL.md` is scanned apart).
bool scansSkillFile(String path, int size) =>
    path != 'SKILL.md' && size <= scannedFileBytes && _scannedName.hasMatch(path);

/// The skills in [files]: every folder holding a `SKILL.md` (nested skills
/// belong to the outer one). A `SKILL.md` at the top takes its folder name
/// from the skill's name, else [fallbackName].
Future<List<ImportCandidate>> findImportCandidates(List<SkillFile> files, {required String fallbackName}) async {
  final kept = [
    for (final f in files)
      if (!SkillRules.ignored(f.path)) f,
  ];
  final roots = <String>{
    for (final f in kept)
      if (f.kind == SkillEntryKind.file && (f.path == 'SKILL.md' || f.path.endsWith('/SKILL.md')))
        f.path.length == 8 ? '' : f.path.substring(0, f.path.length - 9),
  };
  bool inside(String path, String root) => root.isEmpty || path == root || path.startsWith('$root/');
  final outer = [
    for (final r in roots)
      if (!roots.any((o) => o != r && o.length < r.length && inside(r, o))) r,
  ]..sort();

  final out = <ImportCandidate>[];
  for (final root in outer) {
    final own = <SkillFile>[
      for (final f in kept)
        if (f.path != root && inside(f.path, root))
          SkillFile(
            root.isEmpty ? f.path : f.path.substring(root.length + 1),
            size: f.size,
            kind: f.kind,
            read: f.read,
            readHead: f.readHead,
          ),
    ];
    final md = own.where((f) => f.path == 'SKILL.md').first;
    String? text;
    if (md.size <= SkillRules.maxSkillMdBytes && md.read != null) {
      text = utf8.decode(await md.read!(), allowMalformed: true);
    } else {
      text = 'x' * (SkillRules.maxSkillMdBytes + 1); // reported as too large
    }
    var dirName = root.isEmpty ? fallbackName : root.split('/').last;
    if (root.isEmpty) {
      try {
        final name = parseFrontMatter(text).fields['name'];
        if (name is String && name.trim().isNotEmpty) dirName = name.trim();
      } on FormatException {
        // The check below reports it.
      }
    }
    // The declared count and size are checked before any file is opened:
    // past either limit the skill is refused anyway, so nothing is read.
    var count = 0;
    var total = 0;
    for (final f in own) {
      if (f.kind != SkillEntryKind.file) continue;
      count++;
      total += f.size;
    }
    final withinLimits = count <= SkillRules.maxFiles && total <= SkillRules.maxTotalBytes;
    final entries = <SkillEntry>[];
    final findings = <InstructionFinding>[];
    for (final f in own) {
      var head = const <int>[];
      if (withinLimits &&
          f.kind == SkillEntryKind.file &&
          f.read != null &&
          f.size >= 2 &&
          f.size <= SkillRules.maxFileBytes) {
        head = await f.head();
      }
      entries.add(SkillEntry(f.path, size: f.size, kind: f.kind, head: head));
      if (withinLimits && f.kind == SkillEntryKind.file && f.read != null && scansSkillFile(f.path, f.size)) {
        findings.addAll(scanInstructions(utf8.decode(await f.read!(), allowMalformed: true), file: f.path));
      }
    }
    final check = checkSkill(dirName: dirName, skillMd: text, entries: entries);
    out.add(
      ImportCandidate(dirName: dirName, check: check, files: own, findings: [...check.report.findings, ...findings]),
    );
  }
  return out;
}

/// The entries of a zip, without unpacking anything yet. Sizes are the
/// declared ones, so an oversized archive is refused before it is inflated.
List<SkillFile> zipFiles(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return [
    for (final f in archive.files)
      if (f.name.isNotEmpty)
        SkillFile(
          f.name.endsWith('/') ? f.name.substring(0, f.name.length - 1) : f.name,
          size: f.isFile ? f.size : 0,
          kind: f.isSymbolicLink
              ? SkillEntryKind.link
              : f.isFile
              ? SkillEntryKind.file
              : SkillEntryKind.directory,
          read: f.isFile ? () async => _inflate(f) : null,
          readHead: f.isFile ? () async => _inflateHead(f) : null,
        ),
  ];
}

/// [f]'s bytes. Inflated into a fresh buffer each time, so the archive keeps
/// no decompressed copy around.
Uint8List _inflate(ArchiveFile f) {
  final out = OutputMemoryStream();
  f.decompress(out);
  return out.getBytes();
}

/// [f]'s first bytes; inflating stops once they are out.
List<int> _inflateHead(ArchiveFile f) {
  final out = _HeadSink();
  try {
    f.decompress(out);
  } on _HeadFull {
    // Enough.
  }
  final bytes = out.getBytes();
  return bytes.length > 4 ? bytes.sublist(0, 4) : bytes;
}

final class _HeadFull implements Exception {
  const _HeadFull();
}

/// A buffer that stops the inflater once it holds 4 bytes.
final class _HeadSink extends OutputMemoryStream {
  _HeadSink() : super(size: 64);

  void _check() {
    if (length >= 4) throw const _HeadFull();
  }

  @override
  void writeByte(int value) {
    super.writeByte(value);
    _check();
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final n = length ?? bytes.length;
    super.writeBytes(bytes, length: n > 64 ? 64 : n);
    _check();
  }

  @override
  void writeStream(InputStream stream) {
    super.writeBytes(stream.readBytes(stream.length > 64 ? 64 : stream.length).toUint8List());
    _check();
  }

  @override
  void writeBackReference(int distance, int count) {
    super.writeBackReference(distance, count);
    _check();
  }
}
