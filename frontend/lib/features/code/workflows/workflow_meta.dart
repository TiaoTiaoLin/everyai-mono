// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// A workflow's `export const meta = {...}`, read without running the file:
// the object is a plain JavaScript literal (unquoted keys, '…' / "…" / `…`
// strings without `${}`, numbers, booleans, null, arrays, trailing commas,
// comments). Anything else (a variable, a call, a template with `${}`) makes
// the meta unreadable, and the file is listed by its name only.

/// What a workflow says about itself.
final class WorkflowMeta {
  const WorkflowMeta({
    this.id,
    this.name,
    this.description = '',
    this.whenToUse = '',
    this.args = '',
    this.phases = const [],
  });

  /// The id it asks for (else the file's stem).
  final String? id;
  final String? name;
  final String description;
  final String whenToUse;

  /// A plain-text description of the args object.
  final String args;
  final List<({String title, String detail})> phases;
}

/// [source]'s meta, or null when it has none the parser can read.
WorkflowMeta? parseWorkflowMeta(String source) {
  final m = RegExp(r'^\s*export\s+const\s+meta\s*=\s*', multiLine: true).firstMatch(source);
  if (m == null) return null;
  final Object? value;
  try {
    value = _Literal(source, m.end).value();
  } on FormatException {
    return null;
  }
  if (value is! Map<String, Object?>) return null;
  final map = value;
  String str(String k) => map[k] is String ? map[k] as String : '';
  final phases = map['phases'];
  return WorkflowMeta(
    id: str('id').isEmpty ? null : str('id'),
    name: str('name').isEmpty ? null : str('name'),
    description: str('description'),
    whenToUse: str('whenToUse'),
    args: str('args'),
    phases: [
      if (phases is List)
        for (final p in phases)
          if (p is Map && p['title'] is String) (title: p['title'] as String, detail: '${p['detail'] ?? ''}'),
    ],
  );
}

final class _Literal {
  _Literal(this.s, this.i);
  final String s;
  int i;

  Never _bad() => throw const FormatException('not a plain literal');

  void _space() {
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        i++;
      } else if (s.startsWith('//', i)) {
        final end = s.indexOf('\n', i);
        i = end < 0 ? s.length : end;
      } else if (s.startsWith('/*', i)) {
        final end = s.indexOf('*/', i + 2);
        if (end < 0) _bad();
        i = end + 2;
      } else {
        return;
      }
    }
  }

  Object? value() {
    _space();
    if (i >= s.length) _bad();
    final c = s[i];
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == "'" || c == '"' || c == '`') return _string(c);
    final word = RegExp(r'-?[0-9.]+(?:[eE][-+]?\d+)?|true|false|null').matchAsPrefix(s, i);
    if (word == null) _bad();
    i = word.end;
    return switch (word[0]!) {
      'true' => true,
      'false' => false,
      'null' => null,
      final n => num.tryParse(n) ?? _bad(),
    };
  }

  Map<String, Object?> _object() {
    i++;
    final out = <String, Object?>{};
    while (true) {
      _space();
      if (i >= s.length) _bad();
      if (s[i] == '}') {
        i++;
        return out;
      }
      final String key;
      if (s[i] == "'" || s[i] == '"') {
        key = _string(s[i]);
      } else {
        final k = RegExp(r'[A-Za-z_$][\w$]*').matchAsPrefix(s, i) ?? _bad();
        i = k.end;
        key = k[0]!;
      }
      _space();
      if (i >= s.length || s[i] != ':') _bad();
      i++;
      out[key] = value();
      _space();
      if (i < s.length && s[i] == ',') {
        i++;
      } else if (i >= s.length || s[i] != '}') {
        _bad();
      }
    }
  }

  List<Object?> _array() {
    i++;
    final out = <Object?>[];
    while (true) {
      _space();
      if (i >= s.length) _bad();
      if (s[i] == ']') {
        i++;
        return out;
      }
      out.add(value());
      _space();
      if (i < s.length && s[i] == ',') {
        i++;
      } else if (i >= s.length || s[i] != ']') {
        _bad();
      }
    }
  }

  String _string(String quote) {
    i++;
    final b = StringBuffer();
    while (i < s.length) {
      final c = s[i++];
      if (c == quote) return b.toString();
      if (quote == '`' && c == r'$' && i < s.length && s[i] == '{') _bad();
      if (c == '\n' && quote != '`') _bad();
      if (c != r'\') {
        b.write(c);
        continue;
      }
      if (i >= s.length) _bad();
      final e = s[i++];
      b.write(switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => e,
      });
    }
    _bad();
  }
}
