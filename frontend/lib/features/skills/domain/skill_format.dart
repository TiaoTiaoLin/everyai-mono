import 'package:flutter/foundation.dart';

import '../../../core/security/untrusted.dart';
import 'hidden_instructions.dart';

/// The Agent Skills format (agentskills.io): a folder with a `SKILL.md` whose
/// front matter names and describes the skill, plus optional `scripts/`,
/// `references/` and `assets/`.
///
/// The field and size rules follow the reference validator `skills-ref`
/// (Apache-2.0); see THIRD_PARTY_NOTICES.md. The file rules (size caps, no
/// links or compiled programs) are ours.
abstract final class SkillRules {
  static const maxName = 64;
  static const maxDescription = 1024;
  static const maxCompatibility = 500;

  /// The front matter keys the standard allows.
  static const fields = {'name', 'description', 'license', 'allowed-tools', 'metadata', 'compatibility'};

  static const maxSkillMdBytes = 256 * 1024;
  static const maxFileBytes = 10 * 1024 * 1024;
  static const maxTotalBytes = 30 * 1024 * 1024;
  static const maxFiles = 500;
  static const maxDepth = 6;

  /// Recommended ceiling for the instructions themselves.
  static const longBodyLines = 500;

  /// Left out of an import without comment: OS and VCS clutter.
  static bool ignored(String path) {
    final parts = path.split('/');
    final last = parts.last;
    return parts.contains('__MACOSX') || parts.contains('.git') || last == '.DS_Store' || last == 'Thumbs.db';
  }
}

/// A parsed `SKILL.md`.
@immutable
final class SkillManifest {
  const SkillManifest({
    required this.name,
    required this.description,
    required this.body,
    this.license,
    this.compatibility,
    this.allowedTools,
    this.metadata = const {},
    this.extraFields = const [],
  });

  final String name;
  final String description;

  /// The instructions after the front matter.
  final String body;
  final String? license;
  final String? compatibility;
  final String? allowedTools;
  final Map<String, String> metadata;

  /// Front matter keys outside [SkillRules.fields] (other tools' extensions).
  final List<String> extraFields;
}

/// The parsed front matter: every top-level key, and the body after it.
typedef FrontMatter = ({Map<String, Object> fields, String body});

/// Reads the YAML front matter of a `SKILL.md`: plain, quoted and block
/// (`|`, `>`) scalars, and one level of nested mapping (`metadata`). Throws
/// [FormatException] with the line for anything else.
FrontMatter parseFrontMatter(String source) {
  final text = source.replaceAll('\r\n', '\n').replaceFirst('﻿', '');
  if (!text.startsWith('---')) throw const FormatException('SKILL.md must start with front matter between --- lines.');
  final lines = text.split('\n');
  if (lines.first.trim() != '---') throw const FormatException('The first line must be --- alone.');
  final end = lines.indexWhere((l) => l.trimRight() == '---', 1);
  if (end < 0) throw const FormatException('The front matter is not closed with a --- line.');
  final fields = <String, Object>{};
  var i = 1;
  String lineError(int at, String what) => 'Front matter line ${at + 1}: $what';
  int indentOf(String l) => l.length - l.trimLeft().length;
  bool blankOrComment(String l) => l.trim().isEmpty || l.trimLeft().startsWith('#');

  while (i < end) {
    final line = lines[i];
    if (blankOrComment(line)) {
      i++;
      continue;
    }
    if (indentOf(line) > 0) throw FormatException(lineError(i, 'unexpected indentation.'));
    final m = RegExp(r'^([A-Za-z0-9_-]+)\s*:(?:\s+(.*))?$').firstMatch(line.trimRight());
    if (m == null) throw FormatException(lineError(i, 'expected "key: value".'));
    final key = m.group(1)!;
    if (fields.containsKey(key)) throw FormatException(lineError(i, 'the key "$key" appears twice.'));
    final raw = (m.group(2) ?? '').trim();
    i++;
    // The indented lines that belong to this key.
    final block = <String>[];
    while (i < end && (lines[i].trim().isEmpty || indentOf(lines[i]) > 0)) {
      block.add(lines[i]);
      i++;
    }
    while (block.isNotEmpty && block.last.trim().isEmpty) {
      block.removeLast();
    }

    if (raw.isEmpty || raw.startsWith('#')) {
      if (block.isEmpty) {
        fields[key] = '';
      } else {
        final map = <String, String>{};
        for (final b in block) {
          if (blankOrComment(b)) continue;
          final e = RegExp(r'^\s+([^:#]+?)\s*:(?:\s+(.*))?$').firstMatch(b.trimRight());
          if (e == null) throw FormatException(lineError(lines.indexOf(b), 'expected "key: value" under $key.'));
          final k = _scalar(e.group(1)!.trim(), (w) => lineError(lines.indexOf(b), w));
          if (map.containsKey(k)) throw FormatException(lineError(lines.indexOf(b), '"$k" appears twice.'));
          map[k] = _scalar((e.group(2) ?? '').trim(), (w) => lineError(lines.indexOf(b), w));
        }
        fields[key] = map;
      }
      continue;
    }
    final header = RegExp(r'^([|>])([+-]?)\s*(?:#.*)?$').firstMatch(raw);
    if (header != null) {
      fields[key] = _blockScalar(block, folded: header.group(1) == '>', chomp: header.group(2)!);
      continue;
    }
    if (raw.startsWith('[') || raw.startsWith('{')) {
      throw FormatException(lineError(i - block.length - 1, 'lists and inline maps are not supported for "$key".'));
    }
    if (block.isNotEmpty) {
      // A plain scalar continued on indented lines folds into one line.
      if (raw.startsWith('"') || raw.startsWith("'")) {
        throw FormatException(lineError(i - block.length - 1, 'a quoted value must stay on one line.'));
      }
      fields[key] = [raw, for (final b in block) b.trim()].where((s) => s.isNotEmpty).join(' ');
      continue;
    }
    fields[key] = _scalar(raw, (w) => lineError(i - 1, w));
  }
  final body = lines.sublist(end + 1).join('\n').trim();
  return (fields: fields, body: body);
}

String _scalar(String raw, String Function(String) where) {
  if (raw.startsWith('"')) {
    final m = RegExp(r'^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$').firstMatch(raw);
    if (m == null) throw FormatException(where('unterminated double quote.'));
    return m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (e) {
      return switch (e.group(1)!) {
        'n' => '\n',
        't' => '\t',
        final c => c,
      };
    });
  }
  if (raw.startsWith("'")) {
    final m = RegExp(r"^'((?:[^']|'')*)'\s*(?:#.*)?$").firstMatch(raw);
    if (m == null) throw FormatException(where('unterminated single quote.'));
    return m.group(1)!.replaceAll("''", "'");
  }
  // A comment starts at " #".
  final hash = raw.indexOf(' #');
  return (hash < 0 ? raw : raw.substring(0, hash)).trim();
}

String _blockScalar(List<String> block, {required bool folded, required String chomp}) {
  final content = block.where((l) => l.trim().isNotEmpty);
  if (content.isEmpty) return '';
  final indent = content.map((l) => l.length - l.trimLeft().length).reduce((a, b) => a < b ? a : b);
  final lines = [for (final l in block) l.trim().isEmpty ? '' : l.substring(indent)];
  String text;
  if (folded) {
    final out = StringBuffer();
    for (var j = 0; j < lines.length; j++) {
      final l = lines[j];
      if (j > 0) out.write(l.isEmpty || lines[j - 1].isEmpty || l.startsWith(' ') ? '\n' : ' ');
      out.write(l);
    }
    text = out.toString().replaceAll(RegExp(r'\n\n'), '\n');
  } else {
    text = lines.join('\n');
  }
  // Values are trimmed when read, so chomping indicators make no difference.
  return chomp == '+' ? '$text\n' : text.trimRight();
}

/// Problems with a skill. [errors] block an import (and turning the skill
/// on); [warnings] are shown.
@immutable
final class SkillReport {
  const SkillReport({
    this.errors = const [],
    this.warnings = const [],
    this.hasScripts = false,
    this.findings = const [],
  });

  final List<String> errors;
  final List<String> warnings;

  /// Hidden or suspicious text in `SKILL.md` (advice for the trust review; also summed up in [warnings]). Bundled
  /// files are scanned on import and at review time, not here.
  final List<InstructionFinding> findings;

  /// It ships `scripts/` or script files: only Code can run them.
  final bool hasScripts;
  bool get ok => errors.isEmpty;
}

/// One file or folder of a skill, relative to the skill folder (`/`-separated).
@immutable
final class SkillEntry {
  const SkillEntry(this.path, {this.size = 0, this.kind = SkillEntryKind.file, this.head = const []});

  final String path;
  final int size;
  final SkillEntryKind kind;

  /// The file's first bytes, to spot compiled programs.
  final List<int> head;
}

enum SkillEntryKind { file, directory, link, other }

/// A checked skill folder: the manifest (null when it can't be read) and the
/// report.
typedef SkillCheck = ({SkillManifest? manifest, SkillReport report});

/// Checks the skill in folder [dirName] with `SKILL.md` text [skillMd] and
/// [entries]. [strict] (on import) also refuses what loading only warns
/// about: front matter keys outside the standard and a name that doesn't
/// match the folder.
SkillCheck checkSkill({
  required String dirName,
  required String? skillMd,
  required List<SkillEntry> entries,
  bool strict = true,
}) {
  final errors = <String>[];
  final warnings = <String>[];
  void lenient(String problem) => (strict ? errors : warnings).add(problem);

  // Files.
  var total = 0, files = 0;
  var scripts = false;
  for (final e in entries) {
    if (SkillRules.ignored(e.path)) continue;
    final parts = e.path.split('/');
    if (e.path.startsWith('/') || parts.contains('..') || e.path.contains('\\') || e.path.contains(':')) {
      errors.add('${e.path}: paths must stay inside the skill folder.');
      continue;
    }
    if (parts.length > SkillRules.maxDepth) errors.add('${e.path}: nested deeper than ${SkillRules.maxDepth} folders.');
    switch (e.kind) {
      case SkillEntryKind.link:
        errors.add('${e.path}: links are not allowed.');
        continue;
      case SkillEntryKind.other:
        errors.add('${e.path}: only plain files and folders are allowed.');
        continue;
      case SkillEntryKind.directory:
        if (parts.first == 'scripts') scripts = true;
        continue;
      case SkillEntryKind.file:
        break;
    }
    files++;
    total += e.size;
    if (e.size > SkillRules.maxFileBytes) errors.add('${e.path}: larger than ${_mib(SkillRules.maxFileBytes)}.');
    if (_compiled(e.head)) errors.add('${e.path}: compiled programs are not allowed; ship scripts as source.');
    if (parts.any((p) => p.startsWith('.'))) warnings.add('${e.path}: hidden file.');
    if (parts.first == 'scripts' || RegExp(r'\.(py|sh|bash|zsh|js|mjs|cjs|ts|rb|pl|ps1|bat|cmd)$').hasMatch(e.path)) {
      scripts = true;
    }
  }
  if (files > SkillRules.maxFiles) errors.add('More than ${SkillRules.maxFiles} files.');
  if (total > SkillRules.maxTotalBytes) errors.add('Larger than ${_mib(SkillRules.maxTotalBytes)} in all.');

  SkillManifest? manifest;
  var findings = const <InstructionFinding>[];
  if (skillMd == null) {
    errors.add('There is no SKILL.md.');
  } else if (skillMd.length > SkillRules.maxSkillMdBytes) {
    errors.add('SKILL.md is larger than ${SkillRules.maxSkillMdBytes ~/ 1024} KB.');
  } else {
    try {
      final fm = parseFrontMatter(skillMd);
      manifest = _manifest(fm, dirName, errors, warnings, lenient);
    } on FormatException catch (e) {
      errors.add(e.message);
    }
    findings = scanInstructions(skillMd, file: 'SKILL.md');
    if (findingsWarning(findings) case final w?) warnings.add(w);
  }
  return (
    manifest: manifest,
    report: SkillReport(errors: errors, warnings: warnings, hasScripts: scripts, findings: findings),
  );
}

SkillManifest? _manifest(
  FrontMatter fm,
  String dirName,
  List<String> errors,
  List<String> warnings,
  void Function(String) lenient,
) {
  final f = fm.fields;
  final extra = [
    for (final k in f.keys)
      if (!SkillRules.fields.contains(k)) k,
  ]..sort();
  if (extra.isNotEmpty) lenient('Front matter fields outside the standard: ${extra.join(', ')}.');
  String? str(String key) {
    final v = f[key];
    if (v == null) return null;
    if (v is! String) {
      errors.add('"$key" must be text.');
      return null;
    }
    return v.trim();
  }

  final name = str('name');
  final nameOk = name != null && name.isNotEmpty;
  if (name == null || name.isEmpty) {
    errors.add('The front matter needs a name.');
  } else {
    for (final p in skillNameProblems(name)) {
      errors.add(p);
    }
    if (name != dirName) lenient('The folder is called "$dirName" but the skill is "$name"; they must match.');
  }
  // What the agent gets: hidden characters removed from every field but the name, which refuses them (the digest
  // stays over the raw file).
  String? clean(String key) => switch (str(key)) {
    final v? => stripHidden(v),
    null => null,
  };
  final description = clean('description');
  if (description == null || description.isEmpty) {
    errors.add('The front matter needs a description.');
  } else {
    if (description.length > SkillRules.maxDescription) {
      errors.add('The description is longer than ${SkillRules.maxDescription} characters.');
    }
    if (RegExp(r'<\s*/?\s*[A-Za-z]').hasMatch(description)) {
      errors.add('The description may not contain XML or HTML tags.');
    }
  }
  final compatibility = clean('compatibility');
  if (compatibility != null && compatibility.length > SkillRules.maxCompatibility) {
    errors.add('"compatibility" is longer than ${SkillRules.maxCompatibility} characters.');
  }
  final license = clean('license');
  final allowedTools = clean('allowed-tools');
  final metadata = switch (f['metadata']) {
    null => const <String, String>{},
    final Map<String, String> m => {for (final e in m.entries) stripHidden(e.key): stripHidden(e.value)},
    '' => const <String, String>{},
    _ => () {
      errors.add('"metadata" must be a mapping of keys to text.');
      return const <String, String>{};
    }(),
  };
  if (fm.body.isEmpty) warnings.add('SKILL.md has no instructions after the front matter.');
  final lines = '\n'.allMatches(fm.body).length + 1;
  if (lines > SkillRules.longBodyLines) {
    warnings.add('The instructions run $lines lines; under ${SkillRules.longBodyLines} keeps them cheap to load.');
  }
  if (hasInlineCommands(fm.body)) {
    warnings.add(
      'The instructions contain !`command` lines. EveryAI shows them to the agent as text and never runs them.',
    );
  }
  if (!nameOk || description == null || description.isEmpty) return null;
  return SkillManifest(
    name: name,
    description: description,
    body: stripHidden(fm.body),
    license: license,
    compatibility: compatibility,
    allowedTools: allowedTools,
    metadata: metadata,
    extraFields: extra,
  );
}

/// What is wrong with [name] as a skill name; empty when it is fine.
List<String> skillNameProblems(String name) => [
  if (name.runes.length > SkillRules.maxName) 'The name is longer than ${SkillRules.maxName} characters.',
  if (name != name.toLowerCase()) 'The name must be lowercase.',
  if (name.startsWith('-') || name.endsWith('-')) 'The name may not start or end with a hyphen.',
  if (name.contains('--')) 'The name may not contain two hyphens in a row.',
  if (!RegExp(r'^[\p{L}\p{N}-]+$', unicode: true).hasMatch(name)) 'The name may use only letters, digits and hyphens.',
];

String _mib(int bytes) => '${bytes ~/ (1024 * 1024)} MB';

bool _compiled(List<int> h) {
  if (h.length < 2) return false;
  if (h[0] == 0x4D && h[1] == 0x5A) return true; // PE (MZ)
  if (h.length < 4) return false;
  final magic = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
  return const {
    0x7F454C46, // ELF
    0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, // Mach-O
    0xCAFEBABE, 0xBEBAFECA, // universal Mach-O / Java class
  }.contains(magic);
}

// Matches what the agent-server would run when it renders a skill: fenced
// blocks, already-escaped commands and inline code come first and are kept.
final _commandPattern = RegExp(r'(```[\s\S]*?(?:```|$))|(\\!`[^`]+`)|((?<!!)`[^`]+`)|!`([^`]+)`');

/// Whether [body] has `!`command`` tokens the agent-server would execute.
bool hasInlineCommands(String body) => _commandPattern.allMatches(body).any((m) => m.group(4) != null);

/// [body] with every `!`command`` escaped, so the agent-server shows it as
/// text instead of running it unasked when the skill is invoked.
String escapeInlineCommands(String body) =>
    body.replaceAllMapped(_commandPattern, (m) => m.group(4) == null ? m.group(0)! : '\\!`${m.group(4)}`');
