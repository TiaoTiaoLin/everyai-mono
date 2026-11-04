import '../../../skills/domain/skill_format.dart';

/// [body] with everything an external CLI would run on load turned into text: `!`cmd`` (the shared escape) and the
/// ```! fenced form Claude Code also runs.
String defuseInlineCommands(String body) {
  final fences = body.replaceAllMapped(RegExp(r'^([ \t]*)(`{3,}|~{3,})!', multiLine: true), (m) => '${m[1]}${m[2]} !');
  return escapeInlineCommands(fences);
}

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
