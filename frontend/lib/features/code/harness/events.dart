import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Harness events, decoded tolerantly: fields the app doesn't use are kept in
/// [HarnessEvent.raw], unknown kinds become [UnknownEvent]. The EveryAI
/// harness emits the `kind`s of OpenHands' agent-server (v1.59, see
/// AGENTS.md), which the app first ran on.
@immutable
sealed class HarnessEvent {
  const HarnessEvent({required this.id, required this.raw});

  /// Event id; empty for streaming deltas.
  final String id;
  final Map<String, Object?> raw;

  static HarnessEvent decode(Map<String, Object?> json) {
    final id = json['id'] as String? ?? '';
    return switch (json['kind']) {
      'MessageEvent' => _message(id, json),
      'ActionEvent' => ActionCall(
        id: id,
        raw: json,
        toolName: json['tool_name'] as String? ?? '',
        toolCallId: json['tool_call_id'] as String? ?? '',
        // Client tools may carry only their tool_call arguments; typed actions win.
        action: {..._toolCallArgs(json), ...?_map(json['action'])},
        thought: _text(json['thought']),
        summary: json['summary'] as String? ?? '',
        risk: json['security_risk'] as String? ?? 'UNKNOWN',
      ),
      'ObservationEvent' => ToolResult(
        id: id,
        raw: json,
        actionId: json['action_id'] as String? ?? '',
        toolName: json['tool_name'] as String? ?? '',
        observation: _map(json['observation']) ?? const {},
        outcome: (_map(json['observation'])?['is_error'] == true) ? ToolOutcome.error : ToolOutcome.ok,
      ),
      'AgentErrorEvent' => ToolResult(
        id: id,
        raw: json,
        actionId: json['action_id'] as String? ?? '',
        toolCallId: json['tool_call_id'] as String? ?? '',
        toolName: json['tool_name'] as String? ?? '',
        observation: {'error': json['error']},
        outcome: ToolOutcome.error,
      ),
      'UserRejectObservation' => ToolResult(
        id: id,
        raw: json,
        actionId: json['action_id'] as String? ?? '',
        toolName: json['tool_name'] as String? ?? '',
        observation: {'reason': json['rejection_reason']},
        outcome: ToolOutcome.rejected,
      ),
      'StreamingDeltaEvent' => StreamDelta(
        raw: json,
        content: json['content'] as String? ?? '',
        reasoning: json['reasoning_content'] as String? ?? '',
        tool: StreamingTool.fromJson(json['tool']),
      ),
      'ConversationStateUpdateEvent' => _state(id, json),
      'ConversationErrorEvent' => ConversationFailure(
        id: id,
        raw: json,
        message: json['detail'] as String? ?? json['message'] as String? ?? json['code'] as String? ?? 'Error',
      ),
      'UsageReport' => UsageReport(
        id: id,
        raw: json,
        input: (json['input_tokens'] as num?)?.toInt() ?? 0,
        output: (json['output_tokens'] as num?)?.toInt() ?? 0,
        cached: (json['cached_tokens'] as num?)?.toInt() ?? 0,
        contextTokens: (json['context_tokens'] as num?)?.toInt(),
        costMicros: (json['cost_micros'] as num?)?.toInt(),
        onPlan: json['on_plan'] == true,
      ),
      final kind => UnknownEvent(id: id, raw: json, kind: '$kind'),
    };
  }

  static HarnessEvent decodeFrame(String frame) {
    final json = jsonDecode(frame);
    if (json is! Map<String, Object?>) return UnknownEvent(id: '', raw: const {}, kind: 'invalid');
    return decode(json);
  }

  static HarnessEvent _message(String id, Map<String, Object?> json) {
    final m = _map(json['llm_message']) ?? const {};
    return ChatMessage(
      id: id,
      raw: json,
      fromUser: json['source'] == 'user' || m['role'] == 'user',
      text: _text(m['content']),
      reasoning: m['reasoning_content'] as String? ?? '',
    );
  }

  static HarnessEvent _state(String id, Map<String, Object?> json) {
    final key = json['key'] as String?;
    final value = json['value'];
    if (key == 'retry' && value is Map<String, Object?>) {
      return RetryState(
        id: id,
        raw: json,
        attempt: (value['attempt'] as num?)?.toInt() ?? 0,
        max: (value['max'] as num?)?.toInt() ?? 0,
        delayMs: (value['delay_ms'] as num?)?.toInt() ?? 0,
        reason: value['reason'] as String? ?? '',
        status: (value['status'] as num?)?.toInt(),
        until: DateTime.fromMillisecondsSinceEpoch((value['until'] as num?)?.toInt() ?? 0),
      );
    }
    final status = switch ((key, value)) {
      ('execution_status', final String s) => s,
      ('full_state', {'execution_status': final String s}) => s,
      _ => null,
    };
    return StateChange(id: id, raw: json, executionStatus: ExecutionStatus.parse(status), key: key ?? '');
  }

  /// The raw arguments the model sent (`tool_call.arguments`).
  static Map<String, Object?> _toolCallArgs(Map<String, Object?> json) {
    final call = _map(json['tool_call']);
    final args = call?['arguments'];
    if (args is String) {
      try {
        if (jsonDecode(args) case final Map<String, Object?> m) return m;
      } on FormatException {
        // fall through
      }
    }
    return const {};
  }

  static Map<String, Object?>? _map(Object? v) => v is Map<String, Object?> ? v : null;

  /// `[{type: text, text}]` → joined text.
  static String _text(Object? content) => switch (content) {
    final String s => s,
    final List<Object?> parts =>
      parts.map((p) => p is Map ? (p['text'] as String? ?? '') : '').where((t) => t.isNotEmpty).join('\n'),
    _ => '',
  };

  /// Text of an observation's `content` list.
  static String contentText(Map<String, Object?> observation) => _text(observation['content']);
}

final class ChatMessage extends HarnessEvent {
  const ChatMessage({
    required super.id,
    required super.raw,
    required this.fromUser,
    required this.text,
    this.reasoning = '',
  });
  final bool fromUser;
  final String text;
  final String reasoning;
}

/// The agent calling a tool. [action] has a `kind` (TerminalAction,
/// FileEditorAction, …); client tools carry their arguments instead.
final class ActionCall extends HarnessEvent {
  const ActionCall({
    required super.id,
    required super.raw,
    required this.toolName,
    required this.toolCallId,
    required this.action,
    this.thought = '',
    this.summary = '',
    this.risk = 'UNKNOWN',
  });
  final String toolName;
  final String toolCallId;
  final Map<String, Object?> action;
  final String thought;
  final String summary;

  /// LOW, MEDIUM, HIGH or UNKNOWN (the agent's own estimate).
  final String risk;

  String get actionKind => action['kind'] as String? ?? '';
  String str(String key) => action[key] as String? ?? '';
}

enum ToolOutcome { ok, error, rejected }

/// The result of an [ActionCall] (matched by [actionId] or [toolCallId]).
final class ToolResult extends HarnessEvent {
  const ToolResult({
    required super.id,
    required super.raw,
    required this.actionId,
    required this.toolName,
    required this.observation,
    required this.outcome,
    this.toolCallId = '',
  });
  final String actionId;
  final String toolCallId;
  final String toolName;
  final Map<String, Object?> observation;
  final ToolOutcome outcome;

  String get text => HarnessEvent.contentText(observation);
}

/// Tokens of the reply being written (not persisted by the server).
final class StreamDelta extends HarnessEvent {
  const StreamDelta({required super.raw, required this.content, required this.reasoning, this.tool}) : super(id: '');
  final String content;
  final String reasoning;

  /// A tool call being written (the EveryAI harness): what it is so far.
  final StreamingTool? tool;
}

/// A tool call the model is still writing: [lines] of content so far for a
/// file, [chars] of arguments in all.
@immutable
final class StreamingTool {
  const StreamingTool({required this.index, required this.name, this.path = '', this.lines = 0, this.chars = 0});

  final int index;
  final String name;
  final String path;
  final int lines;
  final int chars;

  static StreamingTool? fromJson(Object? j) => switch (j) {
    {'index': final num i, 'name': final String n} => StreamingTool(
      index: i.toInt(),
      name: n,
      path: (j as Map)['path'] as String? ?? '',
      lines: (j['lines'] as num?)?.toInt() ?? 0,
      chars: (j['chars'] as num?)?.toInt() ?? 0,
    ),
    _ => null,
  };

  Map<String, Object?> toJson() => {'index': index, 'name': name, 'path': path, 'lines': lines, 'chars': chars};
}

enum ExecutionStatus {
  idle,
  running,
  paused,
  waitingForConfirmation,
  finished,
  error,
  stuck,
  unknown;

  static ExecutionStatus parse(String? s) => switch (s) {
    'idle' => idle,
    'running' => running,
    'paused' => paused,
    'waiting_for_confirmation' => waitingForConfirmation,
    'finished' => finished,
    'error' => error,
    'stuck' => stuck,
    _ => unknown,
  };

  String get wire => switch (this) {
    waitingForConfirmation => 'waiting_for_confirmation',
    _ => name,
  };
}

/// A [StateChange] key whose value lists call ids a driver let run (see
/// `approvedEvent`): no longer waiting for an answer, results still to come.
const approvedCallsKey = 'approved_calls';

final class StateChange extends HarnessEvent {
  const StateChange({required super.id, required super.raw, required this.executionStatus, required this.key});
  final ExecutionStatus executionStatus;
  final String key;
}

/// The model call failed on something transient (overloaded, rate-limited,
/// a dropped connection) and is sent again: attempt [attempt] of [max]
/// starts at [until]. What had streamed of the reply is void. Not persisted
/// (the EveryAI harness sends it live only); the next delta, message or
/// action ends it.
final class RetryState extends HarnessEvent {
  const RetryState({
    required super.id,
    required super.raw,
    required this.attempt,
    required this.max,
    required this.delayMs,
    required this.reason,
    required this.until,
    this.status,
  });
  final int attempt;
  final int max;
  final int delayMs;
  final String reason;
  final int? status;
  final DateTime until;
}

final class ConversationFailure extends HarnessEvent {
  const ConversationFailure({required super.id, required super.raw, required this.message});
  final String message;
}

/// Not from the server: the session's event socket connected or dropped
/// (it reconnects on its own).
final class ConnectionChange extends HarnessEvent {
  const ConnectionChange({required this.connected, this.restarted = false}) : super(id: '', raw: const {});
  final bool connected;

  /// Connected to a different server than before: a run that was going on
  /// was cut off. The EveryAI harness never sets it.
  final bool restarted;
}

/// What one model call (or turn) of an outside driver used, as a delta:
/// [input] counts cached tokens too ([cached] of them), as in the usage
/// meter; over a turn it is the sum of its calls. [contextTokens]: how full
/// the window is now (the latest call's prompt), when the driver knows; the
/// context ring moves only then. [costMicros]: what it cost, when the driver
/// says; [onPlan]: paid by the user's subscription, so it shows but isn't
/// spending. Drivers turn running totals into deltas, and keep [id] stable
/// when history replays.
final class UsageReport extends HarnessEvent {
  const UsageReport({
    required super.id,
    required super.raw,
    required this.input,
    required this.output,
    this.cached = 0,
    this.contextTokens,
    this.costMicros,
    this.onPlan = false,
  });

  /// One with its [raw] filled in, so the remote mirror carries it.
  factory UsageReport.of({
    required String id,
    required int input,
    required int output,
    int cached = 0,
    int? contextTokens,
    int? costMicros,
    bool onPlan = false,
  }) => UsageReport(
    id: id,
    raw: {
      'kind': 'UsageReport',
      'id': id,
      'input_tokens': input,
      'output_tokens': output,
      'cached_tokens': cached,
      'context_tokens': ?contextTokens,
      'cost_micros': ?costMicros,
      'on_plan': onPlan,
    },
    input: input,
    output: output,
    cached: cached,
    contextTokens: contextTokens,
    costMicros: costMicros,
    onPlan: onPlan,
  );

  final int input;
  final int output;
  final int cached;
  final int? contextTokens;
  final int? costMicros;
  final bool onPlan;
}

final class UnknownEvent extends HarnessEvent {
  const UnknownEvent({required super.id, required super.raw, required this.kind});
  final String kind;
}
