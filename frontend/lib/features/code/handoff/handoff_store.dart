// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'handoff.dart';
import 'handoff_store_stub.dart' if (dart.library.io) 'handoff_store_io.dart' as impl;

/// Saves [h] under [sessionDir]`/handoffs/` (one JSON file each, written
/// atomically) and returns its path.
Future<String> saveHandoff(String sessionDir, Handoff h) => impl.saveHandoff(sessionDir, h);

/// The handoffs saved under [sessionDir], newest first; unreadable files are skipped.
Future<List<Handoff>> loadHandoffs(String sessionDir) => impl.loadHandoffs(sessionDir);

/// Where a delta for [harness] starts: the last event it saw when it last
/// led, which is the coverage of the newest handoff away from it. Null when
/// it never led (a full handoff).
HandoffCoverage? lastSeenBy(List<Handoff> newestFirst, String harness) =>
    newestFirst.where((h) => h.fromHarness == harness).firstOrNull?.coverage;

/// Writes a handoff's transcript [markdown] to [relativePath] under
/// [workingDir] (see `handoffTranscriptPath`), keeping that folder out of
/// git. False when it couldn't be written (the handoff then goes without it).
Future<bool> writeHandoffTranscript(String workingDir, String relativePath, String markdown) =>
    impl.writeHandoffTranscript(workingDir, relativePath, markdown);

/// Deletes [dir]: a session's timeline and handoffs (the session is gone).
Future<void> removeTimeline(String dir) => impl.removeTimeline(dir);
