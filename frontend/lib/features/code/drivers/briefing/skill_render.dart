import '../../../skills/domain/skill_format.dart' show SkillManifest;

/// [body] with everything an external CLI would run on load turned into text. Claude Code runs `!`cmd`` anywhere
/// (inside fences too, after whitespace) and a ```! fence anywhere in a line, so this does not skip fenced regions
/// the way the shared escape does: every `!`` gets a backslash and every fence marker followed by `!` a space.
String defuseInlineCommands(String body) =>
    body.replaceAll(RegExp(r'(?<!\\)!`'), r'\!`').replaceAllMapped(RegExp(r'(`{3,}|~{3,})!'), (m) => '${m[1]} !');

/// A `SKILL.md` for the export, rebuilt from [m] rather than copied: `allowed-tools` is dropped (Claude pre-approves
/// tools from it, which would step around our permissions) and inline commands are defused.
String renderSkillMd(SkillManifest m) {
  final b = StringBuffer('---\n')
    ..writeln('name: ${_q(m.name)}')
    ..writeln('description: ${_q(m.description)}');
  if (m.license case final v? when v.isNotEmpty) b.writeln('license: ${_q(v)}');
  if (m.compatibility case final v? when v.isNotEmpty) b.writeln('compatibility: ${_q(v)}');
  // A key with ':' or '#' would not read back.
  final meta = [
    for (final e in m.metadata.entries)
      if (e.key.trim().isNotEmpty && !RegExp(r'[:#\n\r]').hasMatch(e.key)) e,
  ];
  if (meta.isNotEmpty) {
    b.writeln('metadata:');
    for (final e in meta) {
      b.writeln('  ${e.key.trim()}: ${_q(e.value)}');
    }
  }
  b
    ..writeln('---')
    ..writeln()
    ..writeln(defuseInlineCommands(m.body));
  return b.toString();
}

String _q(String v) =>
    '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\r', '').replaceAll('\n', r'\n')}"';
