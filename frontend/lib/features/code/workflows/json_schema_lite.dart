// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

// The part of JSON Schema a workflow's agent() schemas use: type,
// properties, required, items, enum and additionalProperties: false. Other
// keywords are ignored (accepted), so a richer schema still checks what it can.

/// Where [value] breaks [schema], as readable paths (`$.findings[2].severity:
/// expected one of …`); empty when it fits. At most [limit] problems.
List<String> schemaProblems(Object? value, Map<String, Object?> schema, {int limit = 8}) {
  final out = <String>[];
  _check(value, schema, r'$', out, limit);
  return out;
}

void _check(Object? value, Map<String, Object?> schema, String path, List<String> out, int limit) {
  if (out.length >= limit) return;
  final type = schema['type'];
  if (type != null) {
    final types = type is List ? type.map((t) => '$t').toList() : ['$type'];
    if (!types.any((t) => _isType(value, t))) {
      out.add('$path: expected ${types.join(' or ')}, got ${_typeOf(value)}');
      return;
    }
  }
  if (schema['enum'] case final List<Object?> options) {
    final v = jsonEncode(value);
    if (!options.any((o) => jsonEncode(o) == v)) {
      out.add('$path: expected one of ${options.map(jsonEncode).join(', ')}, got ${_clip(v)}');
      return;
    }
  }
  if (value is Map) {
    final props = (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
    for (final name in (schema['required'] as List?) ?? const []) {
      if (!value.containsKey(name)) out.add('$path: missing required field "$name"');
    }
    for (final MapEntry(:key, value: v) in value.entries) {
      if (props[key] case final Map<String, Object?> sub) {
        _check(v, sub, '$path.$key', out, limit);
      } else if (schema['additionalProperties'] == false) {
        out.add('$path: unexpected field "$key"');
      }
      if (out.length >= limit) return;
    }
  } else if (value is List) {
    if (schema['items'] case final Map<String, Object?> items) {
      for (var i = 0; i < value.length && out.length < limit; i++) {
        _check(value[i], items, '$path[$i]', out, limit);
      }
    }
  }
}

bool _isType(Object? v, String t) => switch (t) {
  'string' => v is String,
  'number' => v is num,
  'integer' => v is int || (v is double && v == v.roundToDouble()),
  'boolean' => v is bool,
  'object' => v is Map,
  'array' => v is List,
  'null' => v == null,
  _ => true,
};

String _typeOf(Object? v) => switch (v) {
  null => 'null',
  String() => 'string',
  num() => 'number',
  bool() => 'boolean',
  Map() => 'object',
  List() => 'array',
  _ => 'unknown',
};

String _clip(String s) => s.length > 60 ? '${s.substring(0, 60)}…' : s;

/// The JSON value an agent's reply ends with: the last ```json (or
/// untagged) fenced block, else the last balanced `{…}` or `[…]`. Null when
/// there is none that parses.
Object? lastJson(String text) {
  // Fences pair up line by line: an opener is a line starting with ```, its
  // closer the next line that is exactly ```. A tagged block (```bash) is
  // skipped whole, so its closer never opens a new block.
  final lines = const LineSplitter().convert(text);
  final blocks = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final open = lines[i].trimLeft();
    if (!open.startsWith('```')) continue;
    final tag = open.substring(3).trim().toLowerCase();
    final start = i + 1;
    var end = start;
    while (end < lines.length && lines[end].trim() != '```') {
      end++;
    }
    if (tag.isEmpty || tag == 'json') blocks.add(lines.sublist(start, end).join('\n'));
    i = end;
  }
  for (final b in blocks.reversed) {
    try {
      return jsonDecode(b.trim());
    } on FormatException {
      // An older fence may still be the answer.
    }
  }
  return _lastBalanced(text, '{', '}') ?? _lastBalanced(text, '[', ']');
}

/// From the innermost [open] before the last [close] outwards: the first
/// that parses up to that [close] is the value the reply ends with.
Object? _lastBalanced(String text, String open, String close) {
  final end = text.lastIndexOf(close);
  if (end < 0) return null;
  for (var i = text.lastIndexOf(open, end); i >= 0; i = i == 0 ? -1 : text.lastIndexOf(open, i - 1)) {
    try {
      return jsonDecode(text.substring(i, end + 1));
    } on FormatException {
      continue;
    }
  }
  return null;
}
