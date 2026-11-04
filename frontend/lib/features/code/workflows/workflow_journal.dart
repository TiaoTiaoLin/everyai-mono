// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

/// What a finished agent() call answered: [value] when [ok], else [error].
typedef JournalledAgent = ({bool ok, Object? value, String? error});

/// One workflow run's steps, one JSON object per line, so a run the app
/// quit in the middle of can carry on (`workflows/<session>/<run>.jsonl`):
/// - `{t:"start", name, source, args}`
/// - `{t:"spawn", key, child}`: the agent's child session started
/// - `{t:"agent", key, ok, value|error}`: it finished
/// - `{t:"phase", title}`
/// - `{t:"end", status, result?, error?}`
///
/// A torn last line (the app quit mid-write) is skipped.
final class WorkflowJournal {
  WorkflowJournal._(this._append);

  /// An empty journal written through [append] (one line at a time).
  WorkflowJournal.fresh(Future<void> Function(String line) append) : this._(append);

  /// The journal [text] holds, written on through [append].
  factory WorkflowJournal.parse(String text, Future<void> Function(String line) append) {
    final j = WorkflowJournal._(append);
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      try {
        if (jsonDecode(line) case final Map<String, Object?> m) j._apply(m);
      } on FormatException {
        // A torn line.
      }
    }
    return j;
  }

  final Future<void> Function(String line) _append;
  Future<void> _tail = Future.value();

  Map<String, Object?>? start;
  final spawns = <String, String>{};
  final agents = <String, JournalledAgent>{};
  final phases = <String>[];
  Map<String, Object?>? end;

  bool get ended => end != null;

  void _apply(Map<String, Object?> m) {
    switch (m['t']) {
      case 'start':
        start = m;
      case 'spawn':
        spawns['${m['key']}'] = '${m['child']}';
      case 'agent':
        agents['${m['key']}'] = (ok: m['ok'] == true, value: m['value'], error: m['error'] as String?);
      case 'phase':
        phases.add('${m['title']}');
      case 'end':
        end = m;
    }
  }

  /// Records [line] and appends it after every earlier write.
  Future<void> write(Map<String, Object?> line) {
    _apply(line);
    final text = jsonEncode(line);
    final next = _tail.then((_) => _append(text));
    _tail = next.catchError((Object _) {});
    return next;
  }

  /// Every write so far has landed.
  Future<void> get flushed => _tail;
}
