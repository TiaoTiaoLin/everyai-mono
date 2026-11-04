// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../harness/events.dart';
import 'event_journal.dart';

EventJournal openEventJournal(String dir, String conversationId) =>
    _FileJournal(File('$dir/${conversationId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.jsonl'));

final class _FileJournal implements EventJournal {
  _FileJournal(this._file);

  final File _file;
  Future<void> _tail = Future.value();

  @override
  void add(HarnessEvent event) {
    if (event is StreamDelta) return;
    final line = '${jsonEncode(event.raw)}\n';
    _tail = _tail
        .then((_) async {
          await _file.parent.create(recursive: true);
          await _file.writeAsString(line, mode: FileMode.append, flush: true);
        })
        .catchError((Object _) {});
  }

  @override
  Future<List<HarnessEvent>> read() async {
    await _tail;
    if (!await _file.exists()) return const [];
    final out = <HarnessEvent>[];
    for (final line in await _file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line);
        if (json is Map<String, Object?>) out.add(HarnessEvent.decode(json));
      } on FormatException {
        // A line cut short by a crash.
      }
    }
    return out;
  }

  @override
  Future<void> close() => _tail;
}
