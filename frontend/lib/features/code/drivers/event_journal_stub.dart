// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/events.dart';
import 'event_journal.dart';

EventJournal openEventJournal(String dir, String conversationId) => _Memory();

final class _Memory implements EventJournal {
  final _events = <HarnessEvent>[];

  @override
  void add(HarnessEvent event) {
    if (event is! StreamDelta) _events.add(event);
  }

  @override
  Future<List<HarnessEvent>> read() async => List.of(_events);

  @override
  Future<void> close() async {}
}
