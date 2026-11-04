// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/events.dart';
import 'event_journal_stub.dart' if (dart.library.io) 'event_journal_io.dart' as impl;

/// The events an outside driver emitted for one conversation, kept as JSON
/// lines in `[dir]/<conversationId>.jsonl` so `attach` can replay the
/// transcript after an app restart. For CLIs whose own history can't be
/// read back in our event shapes. Streaming deltas aren't kept.
abstract interface class EventJournal {
  /// Appends [event] (its `raw` JSON). Writes are serialised.
  void add(HarnessEvent event);

  /// Every event kept so far, oldest first; a torn last line is skipped.
  Future<List<HarnessEvent>> read();

  Future<void> close();
}

EventJournal openEventJournal(String dir, String conversationId) => impl.openEventJournal(dir, conversationId);
