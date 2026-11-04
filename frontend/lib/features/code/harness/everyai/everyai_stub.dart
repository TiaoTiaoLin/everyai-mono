// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:http/http.dart' as http;

import '../events.dart';
import '../harness.dart';

/// The EveryAI harness needs a desktop: it runs commands and edits files.
final class EveryAIHarness implements Harness, ForksSessions {
  EveryAIHarness({required this.dataDir, required this.gatewayKey, http.Client? client});

  final Future<String> Function() dataDir;
  final Future<String> Function() gatewayKey;

  Never _unsupported() => throw UnsupportedError('The EveryAI harness runs on the desktop app.');

  @override
  Future<HarnessSession> start(SessionSpec spec) async => _unsupported();

  @override
  Future<HarnessSession> fork(String parentId, SessionSpec spec) async => _unsupported();

  @override
  Future<HarnessSession> attach(String conversationId) async => _unsupported();

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}
