// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../harness/events.dart';

// The event shapes drivers emit (OpenHands', see `HarnessDriver`), so each
// driver doesn't build the JSON by hand.

/// A tool call: [kind] is one of the app's action kinds when the native
/// tool maps onto one (`TerminalAction {command}`, `FileEditorAction {command,
/// path}`, `ReadFileAction {path}`, `MCPToolAction`), else the driver's own.
ActionCall actionEvent({
  required String id,
  required String toolName,
  required String kind,
  String? toolCallId,
  Map<String, Object?> args = const {},
  String thought = '',
}) => HarnessEvent.decode({
  'kind': 'ActionEvent',
  'id': id,
  'source': 'agent',
  'tool_name': toolName,
  'tool_call_id': toolCallId ?? id,
  'action': {...args, 'kind': kind},
  'tool_call': {'name': toolName, 'arguments': jsonEncode(args)},
  if (thought.isNotEmpty)
    'thought': [
      {'type': 'text', 'text': thought},
    ],
}) as ActionCall;

/// What [actionId]'s call returned: [text], or an error.
ToolResult resultEvent({
  required String id,
  required String actionId,
  required String toolName,
  required String text,
  bool isError = false,
}) => HarnessEvent.decode({
  'kind': 'ObservationEvent',
  'id': id,
  'source': 'environment',
  'action_id': actionId,
  'tool_name': toolName,
  'observation': {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'is_error': isError,
  },
}) as ToolResult;

/// The run's state: waiting for approvals, running, finished, …
StateChange stateEvent(String id, ExecutionStatus status) => HarnessEvent.decode({
  'kind': 'ConversationStateUpdateEvent',
  'id': id,
  'key': 'execution_status',
  'value': status.wire,
}) as StateChange;
