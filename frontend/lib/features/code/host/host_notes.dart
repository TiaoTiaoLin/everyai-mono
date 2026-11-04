// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'host.dart' show HostResult;
import 'host_notes_stub.dart' if (dart.library.io) 'host_notes_io.dart' as impl;

// The host's note tools for an outside agent, run in the project folder the
// way the EveryAI harness runs its own (`project_notes_io.dart`).

/// The memory tool in [root]: add, replace or remove lines in
/// `.everyai/memory.md`.
HostResult hostMemory(String root, Map<String, Object?> args) => impl.hostMemory(root, args);

/// saved_plans in [root]: without a name, the saved plans newest first with
/// their titles; with one, that plan.
HostResult hostSavedPlans(String root, Map<String, Object?> args) => impl.hostSavedPlans(root, args);

/// Saves [markdown] (an approved plan) under `.everyai/plans/`; false when
/// it couldn't be written.
bool hostSavePlan(String root, String markdown) => impl.hostSavePlan(root, markdown);

/// The project memory and latest plan for a new session's briefing (empty
/// when there are none, or no files here).
Future<String> hostProjectNotes(String root) => impl.hostProjectNotes(root);
