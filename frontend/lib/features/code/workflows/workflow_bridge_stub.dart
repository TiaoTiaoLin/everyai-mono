// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'workflow_bridge.dart';

Future<WorkflowBridge> startWorkflowBridge({
  required String dir,
  required String source,
  required Map<String, Object?> args,
}) async => throw StateError('Workflows run on the desktop app only.');

Future<String> readJournalFile(String path) async => '';
Future<void> appendJournalFile(String path, String line) async {}
Future<List<String>> listJournalFiles(String dir) async => const [];
