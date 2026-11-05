// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// Checks on the tools an MCP server offers, before the model sees them.
///
/// A tool's description and schema are in the model's context from the first
/// token, whether or not the tool is ever called, so a server can attack
/// before any approval card ("tool poisoning", "line jumping"), change a
/// description after the user trusted it ("rug pull"), or talk about other
/// tools ("shadowing"). [scanMcpTool] flags what looks smuggled, and
/// [vetMcpTools] keeps only tools whose [mcpToolDigest] the user accepted:
/// clean tools are pinned at their server's first session, anything flagged,
/// changed or new waits for an Allow in Settings → MCP servers.
///
/// No model calls: regexes and hashing only. The scan is a tripwire (English,
/// easy to paraphrase); pinning and the untrusted wrapper on results are the
/// guarantees.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/security/untrusted.dart';

/// One tool of a server that sessions leave out until the user allows it.
final class McpToolReview {
  const McpToolReview({
    required this.name,
    required this.digest,
    this.description = '',
    this.reasons = const [],
    this.isNew = false,
  });

  /// The server's own name for the tool.
  final String name;

  /// [mcpToolDigest] of the tool as it was seen; Allow pins this one.
  final String digest;

  /// What the tool tells the model, hidden characters removed, shortened.
  final String description;

  /// Why it needs a look, in plain words.
  final List<String> reasons;

  /// Not seen before (rather than changed since it was allowed).
  final bool isNew;

  /// [scanMcpTool] found something (more than a change).
  bool get flagged => reasons.any((r) => r != changedReason);

  static const changedReason = 'Changed since you allowed it.';

  static McpToolReview? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final name = json['name'];
    final digest = json['digest'];
    if (name is! String || digest is! String) return null;
    final reasons = json['reasons'];
    return McpToolReview(
      name: name,
      digest: digest,
      description: json['description'] as String? ?? '',
      reasons: [
        if (reasons is List<Object?>)
          for (final r in reasons)
            if (r is String) r,
      ],
      isNew: json['new'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'digest': digest,
    if (description.isNotEmpty) 'description': description,
    if (reasons.isNotEmpty) 'reasons': reasons,
    if (isNew) 'new': true,
  };
}

/// What one session learned about a server's tools: digests to pin (first
/// use) and the tools left out, which replace the server's stored list.
final class McpToolsReport {
  const McpToolsReport({this.pin = const {}, this.pending = const []});

  /// Tool name to digest, for a server never seen before.
  final Map<String, String> pin;
  final List<McpToolReview> pending;
}

/// SHA-256 of what the model sees of [tool] (name, description, input
/// schema) as canonical JSON, keys sorted at every level. Computed on the raw
/// text, so one hidden character is a change.
String mcpToolDigest(Map<String, Object?> tool) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonical({
            'name': tool['name'] ?? '',
            'description': tool['description'] ?? '',
            'inputSchema': tool['inputSchema'],
          }),
        ),
      ),
    )
    .toString();

Object? _canonical(Object? v) => switch (v) {
  Map() => {for (final k in (v.keys.map((k) => '$k').toList()..sort())) k: _canonical(v[k])},
  List() => [for (final e in v) _canonical(e)],
  _ => v,
};

final _markup = RegExp(
  r'<\s*/?\s*(important|system|instructions?|admin|secret)\b|<!--|\[/?INST\]|<\|im_start\|>',
  caseSensitive: false,
);
final _conceal = [
  RegExp(
    r"\b(do\s*n[o'’]?t|never)\s+(tell|mention|show|inform|reveal|notify|alert)\b[^.\n]{0,40}\buser",
    caseSensitive: false,
  ),
  RegExp(r'without\s+(telling|informing|notifying|alerting|asking)\s+the\s+user', caseSensitive: false),
  RegExp(r'the\s+user\s+(must|should)\s+(not|never)\s+(know|see|notice|find\s+out)', caseSensitive: false),
  RegExp(r'\b(hide|conceal)\b[^.\n]{0,40}\bfrom\s+the\s+user', caseSensitive: false),
];
final _override = [
  RegExp(
    r'\b(ignore|disregard|forget)\s+(all\s+|any\s+)?(the\s+)?(previous|prior|other|earlier|above|your)?\s*'
    r'(instructions|rules|guidelines|directions|system\s+prompt)',
    caseSensitive: false,
  ),
  RegExp(r'\b(before|after)\s+(using|calling|running)\s+(any|every|another|other)\s+tools?', caseSensitive: false),
  RegExp(r'\balways\s+(call|use|run)\s+this\s+tool\s+first', caseSensitive: false),
];
const _secretTargets =
    r'(\.ssh\b|id_rsa|id_ed25519|\.env\b|\.aws\b|\.netrc|mcp\.json|credentials\.json|\.git-credentials|\.npmrc|'
    r'\.pypirc|private[ _-]?key|keychain)';
const _secretVerbs = r'\b(read|cat|include|send|pass|upload|copy|attach|forward|extract|provide|post)\b';
final _secretReach = RegExp(
  '$_secretVerbs[^\\n]{0,60}?$_secretTargets|$_secretTargets[^\\n]{0,60}?$_secretVerbs',
  caseSensitive: false,
);
final _secretParam = RegExp(
  r'id_rsa|id_ed25519|ssh_?key|private_?key|system_?prompt|chat_?history|conversation_?history|previous_?messages',
  caseSensitive: false,
);
final _otherToolUse = RegExp(
  r'''\bwhen\s+(using|calling)\s+(?!(this|these|that|the\s+tool)\b)(the\s+)?[`'"]?[\w-]+[`'"]?\s+tool\b''',
  caseSensitive: false,
);

/// Whether [text] names tool [name]: names with `_`, `-` or camelCase as a
/// whole word; plain words only in backticks or as "the X tool", so English
/// doesn't trip it.
bool _names(String text, String name) {
  if (name.length < 3) return false;
  final n = RegExp.escape(name);
  final distinctive = name.contains('_') || name.contains('-') || RegExp('[a-z][A-Z]').hasMatch(name);
  if (distinctive && RegExp('(?<![A-Za-z0-9_-])$n(?![A-Za-z0-9_-])').hasMatch(text)) return true;
  return RegExp('`$n`|\\bthe\\s+$n\\s+tool\\b', caseSensitive: false).hasMatch(text);
}

/// Why [tool] looks unsafe to show the model, in plain words (empty: clean).
/// [otherTools] are other servers' tool names, [builtIns] the harness's own;
/// [ownTools] (this server's) may be named freely.
List<String> scanMcpTool(
  Map<String, Object?> tool, {
  Set<String> otherTools = const {},
  Set<String> builtIns = const {},
  Set<String> ownTools = const {},
}) {
  final name = tool['name'] as String? ?? '';
  final description = tool['description'] as String? ?? '';
  final strings = <String>[description];
  final params = <String>[];
  void walk(Object? v) {
    switch (v) {
      case Map():
        for (final e in v.entries) {
          strings.add('${e.key}');
          if (e.key == 'properties' && e.value is Map) params.addAll([for (final k in (e.value as Map).keys) '$k']);
          walk(e.value);
        }
      case List():
        v.forEach(walk);
      case String():
        strings.add(v);
    }
  }

  walk(tool['inputSchema']);
  final reasons = <String>[];
  void add(String why) {
    if (!reasons.contains(why)) reasons.add(why);
  }

  final hidden = <HiddenKind>{
    for (final s in [name, ...strings]) ...hiddenIn(s),
  };
  if (hidden.isNotEmpty) {
    add(
      'Has hidden characters (${[for (final k in HiddenKind.values)
        if (hidden.contains(k)) k.label].join(', ')}).',
    );
  }
  final text = stripHidden(strings.join('\n'));
  if (_markup.hasMatch(text)) add('Has markup that poses as system instructions.');
  if (_conceal.any((r) => r.hasMatch(text))) add('Tells the agent to keep something from you.');
  if (_override.any((r) => r.hasMatch(text))) add('Tells the agent to set aside its instructions or other tools.');
  if (_secretReach.firstMatch(text) case final m?) add('Points the agent at secrets (${m[0]!.trim()}).');
  for (final p in params) {
    if (_secretParam.hasMatch(p)) add('Has a parameter that asks for secrets or the conversation: ${stripHidden(p)}.');
  }
  final own = {...ownTools, name};
  for (final other in (otherTools.difference(own).toList()..sort())) {
    if (_names(text, other)) add("Mentions another server's tool: $other.");
  }
  for (final b in (builtIns.difference(own).toList()..sort())) {
    if (_names(text, b)) add('Mentions the built-in tool $b.');
  }
  if (_otherToolUse.firstMatch(text) case final m? when !own.any((o) => m[0]!.contains(o))) {
    add('Tells the agent how to use another tool.');
  }
  return reasons;
}

/// [tools] as sessions may see them: kept are those whose digest is in
/// [pinned]; with [pinned] null (the server's first session) the clean ones
/// too, and the report says to pin them. The rest are left out, listed in
/// the report for Settings. Kept tools lose hidden characters in their
/// description and schema (the name stays: the server is called by it).
({List<Map<String, Object?>> kept, McpToolsReport report}) vetMcpTools(
  List<Map<String, Object?>> tools, {
  Map<String, String>? pinned,
  Set<String> otherTools = const {},
  Set<String> builtIns = const {},
}) {
  final own = {
    for (final t in tools)
      if (t['name'] case final String n) n,
  };
  final kept = <Map<String, Object?>>[];
  final pin = <String, String>{};
  final pending = <McpToolReview>[];
  for (final t in tools) {
    final name = t['name'];
    if (name is! String || name.isEmpty) continue;
    final digest = mcpToolDigest(t);
    if (pinned?[name] == digest) {
      kept.add(_stripped(t));
      continue;
    }
    final reasons = scanMcpTool(t, otherTools: otherTools, builtIns: builtIns, ownTools: own);
    if (pinned == null && reasons.isEmpty) {
      kept.add(t);
      pin[name] = digest;
      continue;
    }
    final changed = pinned != null && pinned.containsKey(name);
    var description = stripHidden(t['description'] as String? ?? '').trim();
    if (description.length > 1500) description = '${description.substring(0, 1500)}…';
    pending.add(
      McpToolReview(
        name: name,
        digest: digest,
        description: description,
        reasons: [if (changed) McpToolReview.changedReason, ...reasons],
        isNew: !changed,
      ),
    );
  }
  return (kept: kept, report: McpToolsReport(pin: pin, pending: pending));
}

Map<String, Object?> _stripped(Map<String, Object?> tool) {
  Object? strip(Object? v) => switch (v) {
    String() => stripHidden(v),
    Map() => {for (final e in v.entries) stripHidden('${e.key}'): strip(e.value)},
    List() => [for (final e in v) strip(e)],
    _ => v,
  };
  return {
    ...tool,
    if (tool['description'] case final Object d) 'description': strip(d),
    if (tool['inputSchema'] case final Object s) 'inputSchema': strip(s),
  };
}
