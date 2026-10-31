// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:http/http.dart' as http;

import '../harness.dart';
import 'everyai_stub.dart' if (dart.library.io) 'everyai_harness_io.dart' as impl;

/// The EveryAI harness (desktop only: it runs commands and edits files on
/// this computer). See `everyai_harness_io.dart`.
Harness everyAIHarness({
  required Future<String> Function() dataDir,
  required Future<String> Function() gatewayKey,
  http.Client? client,
}) => impl.EveryAIHarness(dataDir: dataDir, gatewayKey: gatewayKey, client: client);

/// Starts [spec] as a fork of [parentConversationId] when [harness] can fork
/// (the EveryAI harness); null otherwise.
Future<HarnessSession>? forkSession(Harness harness, String parentConversationId, SessionSpec spec) =>
    harness is impl.EveryAIHarness ? harness.fork(parentConversationId, spec) : null;
