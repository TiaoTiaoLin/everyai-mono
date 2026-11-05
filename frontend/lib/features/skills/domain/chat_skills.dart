import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/security/untrusted.dart';
import '../../chat/domain/message.dart' show ToolCallPart;
import 'hidden_instructions.dart';
import 'skill_catalog.dart';

/// The chat tools that bring the user's skills into a conversation. Both run
/// on the device (`client_tools`): the skills live in the local library.
const loadSkillTool = 'load_skill';
const readSkillFileTool = 'read_skill_file';
const skillChatTools = {loadSkillTool, readSkillFileTool};

/// The most of a skill's instructions or one of its files the model gets.
const skillTextMax = 60000;

/// The most text the `<skills>` catalog may take (the server allows 32 KiB).
const skillCatalogMax = 24000;

/// One skill as Chat sees it.
@immutable
final class ChatSkill {
  const ChatSkill({
    required this.name,
    required this.description,
    required this.body,
    required this.dir,
    this.files = const [],
    this.needsCode = false,
  });

  factory ChatSkill.of(InstalledSkill s) => ChatSkill(
    name: s.name,
    description: s.manifest!.description,
    body: s.manifest!.body,
    dir: s.dir,
    files: s.files,
    needsCode: skillNeedsCode(s),
  );

  final String name;
  final String description;
  final String body;
  final String dir;
  final List<String> files;

  /// It runs programs (ships scripts, or says it needs an interpreter or a
  /// shell), which only a Code session can do. Listed in Chat, but refused.
  final bool needsCode;
}

final _runsPrograms = RegExp(
  r'\b(python3?|node(\.js)?|bash|zsh|shell|terminal|command[- ]line|pip|npm|npx|uv|docker|code execution|sandbox)\b',
  caseSensitive: false,
);

/// [s] needs a terminal: it ships scripts, its `compatibility` names a
/// runtime or shell, or its `allowed-tools` asks for Bash.
bool skillNeedsCode(InstalledSkill s) {
  if (s.report.hasScripts) return true;
  final m = s.manifest;
  if (m == null) return false;
  if (m.compatibility case final c? when _runsPrograms.hasMatch(c)) return true;
  if (m.allowedTools case final t? when RegExp(r'\bBash\b').hasMatch(t)) return true;
  return false;
}

/// The skills Chat offers: the active library and shared ones (project
/// skills belong to their Code project), sorted by name.
List<ChatSkill> chatSkills(List<InstalledSkill> all, SkillSettings settings) => [
  for (final s in sessionSkills(all, settings, null)) ChatSkill.of(s),
];

/// The `<skills>` block sent after the memory block: one line per skill,
/// sorted, no dates or counters, so the bytes stay the same until the
/// user's skills change (it caches with the prefix before it). Null when
/// there are none.
String? skillCatalogBlock(List<ChatSkill> skills) {
  if (skills.isEmpty) return null;
  final sorted = [...skills]..sort((a, b) => a.name.compareTo(b.name));
  final out = StringBuffer()
    ..writeln('<skills>')
    ..writeln(
      "The user's skills. When a request matches one, call load_skill with its name first and follow it. "
      'Skills marked (needs Code) run programs and only work in a Code session.',
    );
  const end = '</skills>';
  var left = sorted.length;
  for (final s in sorted) {
    final line =
        '- ${s.name}${s.needsCode ? ' (needs Code)' : ''}: ${s.description.replaceAll(RegExp(r'\s+'), ' ').trim()}';
    if (out.length + line.length + 80 > skillCatalogMax) break;
    out.writeln(line);
    left--;
  }
  if (left > 0) out.writeln('- …and $left more not listed; load_skill accepts their exact names too.');
  out.write(end);
  return out.toString();
}

/// What a skill tool call returns to the model.
typedef SkillToolResult = ({String text, bool isError});

/// Runs `load_skill` and `read_skill_file` against the user's [skills].
final class SkillChatTools {
  const SkillChatTools(this.skills, {required this.readFile});

  final List<ChatSkill> skills;

  /// The bytes of a file in a skill folder, or null (see `readSkillFileBytes`).
  final Future<List<int>?> Function(String dir, String rel) readFile;

  bool handles(String name) => skillChatTools.contains(name);

  ChatSkill? find(String name) {
    final n = name.trim();
    return skills.where((s) => s.name == n).firstOrNull ??
        skills.where((s) => s.name.toLowerCase() == n.toLowerCase()).firstOrNull;
  }

  /// Never throws. [loaded]: skills this chat loaded before, which are not
  /// sent again.
  Future<SkillToolResult> run(String tool, Map<String, Object?> args, {Set<String> loaded = const {}}) async {
    String str(String k) => (args[k] is String ? args[k] as String : '').trim();
    final name = tool == loadSkillTool ? str('name') : str('skill');
    if (name.isEmpty) return (text: 'Error: give the skill name from the <skills> list.', isError: true);
    final skill = find(name);
    if (skill == null) {
      final names = skills.map((s) => s.name).join(', ');
      return (
        text: skills.isEmpty
            ? 'Error: the user has no skills turned on. Carry on without one.'
            : 'Error: no skill is named "$name". The user\'s skills: $names.',
        isError: true,
      );
    }
    if (skill.needsCode) {
      return (
        text:
            'Error: the skill "${skill.name}" runs programs, which only a Code session can do. Tell the user it '
            'works in Code, and help here without it if you can.',
        isError: true,
      );
    }
    try {
      return tool == loadSkillTool ? _load(skill, loaded) : await _read(skill, str('path'));
    } on Object catch (e) {
      return (text: 'Error: $tool failed on the device ($e).', isError: true);
    }
  }

  SkillToolResult _load(ChatSkill skill, Set<String> loaded) {
    if (loaded.contains(skill.name)) {
      return (
        text: 'The skill "${skill.name}" is already loaded earlier in this chat; follow it from there.',
        isError: false,
      );
    }
    final out = StringBuffer()
      ..writeln('<skill_content name="${skill.name}">')
      ..writeln(_cap(stripHidden(skill.body).trim()))
      ..write('</skill_content>');
    if (skill.files.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Files in this skill (open one with read_skill_file when the instructions point to it):');
      for (final f in skill.files.take(100)) {
        out.writeln('- $f');
      }
      if (skill.files.length > 100) out.writeln('- …and ${skill.files.length - 100} more');
    }
    return (text: out.toString().trimRight(), isError: false);
  }

  Future<SkillToolResult> _read(ChatSkill skill, String raw) async {
    final path = normalizeSkillPath(raw);
    if (path == null) {
      return (
        text: 'Error: "$raw" is not a path inside the skill. Use one from the list load_skill gave.',
        isError: true,
      );
    }
    if (path == 'SKILL.md') return _load(skill, const {});
    if (!skill.files.contains(path)) {
      return (
        text:
            'Error: the skill "${skill.name}" has no file "$path".'
            '${skill.files.isEmpty ? ' It has no files besides its instructions.' : ' Its files: ${skill.files.take(40).join(', ')}.'}',
        isError: true,
      );
    }
    final bytes = await readFile(skill.dir, path);
    if (bytes == null) return (text: 'Error: "$path" could not be read (missing or too large).', isError: true);
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return (text: 'Error: "$path" is not a text file, so it cannot be read in a chat.', isError: true);
    }
    // Hidden characters never reach the model; the note says they were there.
    final note = hiddenRemovedNote(text);
    return (
      text:
          '<skill_file skill="${skill.name}" path="$path">\n${_cap(stripHidden(text))}\n</skill_file>'
          '${note == null ? '' : '\n$note'}',
      isError: false,
    );
  }
}

String _cap(String text) => text.length <= skillTextMax ? text : '${text.substring(0, skillTextMax)}\n[truncated]';

/// [raw] as a relative `/`-separated path inside a skill folder, or null
/// when it leaves the folder or is absolute.
String? normalizeSkillPath(String raw) {
  var p = raw.trim();
  if (p.isEmpty || p.contains('\\') || p.contains('\u0000') || p.startsWith('/') || p.contains(':')) return null;
  final parts = [
    for (final s in p.split('/'))
      if (s.isNotEmpty && s != '.') s,
  ];
  if (parts.isEmpty || parts.contains('..')) return null;
  p = parts.join('/');
  return p;
}

Map<String, Object?>? _result(ToolCallPart call) {
  final raw = call.resultJson;
  if (raw == null) return null;
  try {
    return switch (jsonDecode(raw)) {
      final Map<String, Object?> m => m,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

Map<String, Object?> _args(ToolCallPart call) {
  try {
    return switch (jsonDecode(call.argumentsJson)) {
      final Map<String, Object?> m => m,
      _ => const {},
    };
  } on FormatException {
    return const {};
  }
}

/// The skills [calls] loaded successfully, by name.
Set<String> loadedSkillsIn(Iterable<ToolCallPart> calls) => {
  for (final c in calls)
    if (c.toolName == loadSkillTool)
      if (_result(c) case final r? when r['error'] != true && '${r['text']}'.startsWith('<skill_content'))
        if (_args(c)['name'] case final String n) n.trim(),
};

/// What a successful skill call in an earlier turn gave the model, so later
/// turns still have the instructions (the server only sees text history).
String? skillCallNote(ToolCallPart call) {
  if (!skillChatTools.contains(call.toolName)) return null;
  final r = _result(call);
  if (r == null || r['error'] == true) return null;
  final text = r['text'];
  if (text is! String || !(text.startsWith('<skill_content') || text.startsWith('<skill_file'))) return null;
  return text;
}

/// (label, detail) for the transcript chip of a skill call.
({String label, String detail}) describeSkillCall(ToolCallPart call, {required bool pending, required bool failed}) {
  final args = _args(call);
  String str(String k) => (args[k] is String ? args[k] as String : '').trim();
  if (call.toolName == readSkillFileTool) {
    final label = failed ? "Couldn't read a skill file" : (pending ? 'Reading a skill file…' : 'Read a skill file');
    return (label: label, detail: [str('skill'), str('path')].where((s) => s.isNotEmpty).join('/'));
  }
  final label = failed ? "Couldn't use a skill" : (pending ? 'Loading a skill…' : 'Used a skill');
  return (label: label, detail: str('name'));
}
