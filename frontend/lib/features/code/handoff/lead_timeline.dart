// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../drivers/event_journal.dart';
import '../harness/events.dart';
import 'handoff.dart' show HandoffCoverage;

// A session that changed leads keeps what each earlier lead did, one
// segment per stint, so the transcript stays one timeline after a restart
// and a lead coming back gets only what it missed. Segments are appended to
// `<dir>/timeline.jsonl` when a lead leaves; the current lead's events live
// in its own conversation until then.

/// The kind of the event that opens a segment (folded as an unknown event).
const leadSegmentKind = 'EveryAILeadSegment';

/// One stint of one lead: its harness, the conversation it ran in, and the
/// events it added (a conversation reopened later replays its older events
/// again; those are not repeated here).
typedef LeadSegment = ({String harness, String conversationId, List<HarnessEvent> events});

EventJournal _journal(String dir) => openEventJournal(dir, 'timeline');

/// The segments kept under [dir], oldest first.
Future<List<LeadSegment>> readTimeline(String dir) async => splitSegments(await _journal(dir).read());

/// Appends [segment] under [dir].
Future<void> appendSegment(String dir, LeadSegment segment) async {
  final j = _journal(dir)
    ..add(
      HarnessEvent.decode({
        'id': '',
        'kind': leadSegmentKind,
        'harness': segment.harness,
        'conversation_id': segment.conversationId,
      }),
    );
  for (final e in segment.events) {
    j.add(e);
  }
  await j.close();
}

/// [journal] cut at each segment header; events before the first are dropped.
List<LeadSegment> splitSegments(List<HarnessEvent> journal) {
  final out = <LeadSegment>[];
  for (final e in journal) {
    if (e is UnknownEvent && e.kind == leadSegmentKind) {
      out.add((
        harness: e.raw['harness'] as String? ?? '',
        conversationId: e.raw['conversation_id'] as String? ?? '',
        events: <HarnessEvent>[],
      ));
    } else if (out.isNotEmpty) {
      out.last.events.add(e);
    }
  }
  return out;
}

/// [since] when the record [segments] + [current] finds it where it is: in
/// the last segment of its conversation. Ids are unique per conversation
/// only, so when a later event elsewhere has the same id (a counter two
/// harnesses share), a delta from it would start at the wrong place: null
/// then, which makes the handoff full.
HandoffCoverage? placedSince(List<LeadSegment> segments, List<HarnessEvent> current, HandoffCoverage? since) {
  if (since == null || since.eventId.isEmpty) return null;
  var offset = 0;
  int? at;
  for (final s in segments) {
    if (s.conversationId == since.conversationId) {
      final i = s.events.lastIndexWhere((e) => e.id == since.eventId);
      if (i >= 0) at = offset + i;
    }
    offset += s.events.length;
  }
  if (at == null) return since;
  final record = [for (final s in segments) ...s.events, ...current];
  return record.lastIndexWhere((e) => e.id == since.eventId) == at ? since : null;
}
