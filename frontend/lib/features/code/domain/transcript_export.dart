import 'dart:convert';

import '../../usage/usage_totals.dart';
import '../git/repo_check.dart' show splitRepoCheck;
import '../harness/events.dart';
import 'agent_mode.dart' show splitModeNote;
import 'code_session.dart';

/// A session as Markdown, for reading or comparing runs: a header with the
/// harness, model, cost and duration, then every message, tool call and
/// result in order (results cut to [resultCap] characters).
String transcriptMarkdown(CodeSessionInfo info, List<HarnessEvent> events, {UsageTotals? usage, int resultCap = 4000}) {
  final out = StringBuffer('# ${info.title}\n\n');
  DateTime? first, last;
  for (final e in events) {
    final at = _time(e);
    if (at == null) continue;
    first ??= at;
    last = at;
  }
  final calls = events.whereType<ActionCall>().toList();
  final byTool = <String, int>{};
  for (final c in calls) {
    byTool[c.toolName] = (byTool[c.toolName] ?? 0) + 1;
  }
  out
    ..writeln('- Harness: ${info.harness}')
    ..writeln('- Model: ${info.model}${info.effort.isEmpty ? '' : ' · effort ${info.effort}'}')
    ..writeln('- Mode at start: ${info.mode.name}')
    ..writeln(
      '- Folder: ${info.workingDir}${info.worktree == null ? ' (in place)' : ' (worktree ${info.worktree!.branch})'}',
    )
    ..writeln('- Started: ${info.createdAt.toIso8601String()}');
  if (first != null && last != null) out.writeln('- Span of the events: ${_duration(last.difference(first))}');
  if (usage != null) {
    out.writeln(
      '- Usage: ${usage.calls} model calls, ${usage.promptTokens} input tokens (${usage.cachedTokens} cached), '
      '${usage.completionTokens} output tokens, \$${(usage.chargedMicros / 1e6).toStringAsFixed(2)}',
    );
  }
  out.writeln(
    '- Tool calls: ${calls.length}${byTool.isEmpty ? '' : ' (${(byTool.entries.toList()..sort((a, b) => b.value - a.value)).map((e) => '${e.key} ${e.value}').join(', ')})'}',
  );
  out
    ..writeln()
    ..write(transcriptSteps(events, resultCap: resultCap));
  return out.toString();
}

/// [events] as Markdown, oldest first: each message, tool call and result
/// (results cut to [resultCap] characters), stamped with the time since the
/// first event when the events carry timestamps.
String transcriptSteps(List<HarnessEvent> events, {int resultCap = 4000}) {
  final out = StringBuffer();
  DateTime? first;
  for (final e in events) {
    first = _time(e);
    if (first != null) break;
  }
  final callsById = {for (final c in events.whereType<ActionCall>()) c.id: c};
  for (final e in events) {
    final at = _time(e);
    final stamp = at == null || first == null ? '' : ' _(+${_duration(at.difference(first))})_';
    switch (e) {
      case ChatMessage(fromUser: true, :final text):
        out
          ..writeln('## User$stamp\n')
          ..writeln(splitRepoCheck(splitModeNote(text).$2).$2.trim())
          ..writeln();
      case ChatMessage(:final text, :final reasoning):
        if (text.trim().isEmpty && reasoning.trim().isEmpty) continue;
        out.writeln('### Agent$stamp\n');
        if (reasoning.trim().isNotEmpty) {
          out.writeln('<details><summary>Thinking</summary>\n\n${reasoning.trim()}\n\n</details>\n');
        }
        if (text.trim().isNotEmpty) out.writeln('${text.trim()}\n');
      case ActionCall(actionKind: 'ProposedPlanAction', :final action):
        out.writeln('### Agent$stamp\n\n${'${action['body'] ?? ''}'.trim()}\n');
      case ActionCall(:final toolName, :final action):
        final args = Map.of(action)..remove('kind');
        final command = action['command'];
        out.writeln('**→ $toolName**$stamp');
        out.writeln(
          toolName == 'bash' || action['kind'] == 'TerminalAction'
              ? '```sh\n${command ?? ''}\n```'
              : '```json\n${_cap(const JsonEncoder.withIndent('  ').convert(args), 1500)}\n```',
        );
      case ToolResult(:final actionId, :final outcome):
        final call = callsById[actionId];
        final label = switch (outcome) {
          ToolOutcome.ok => 'result',
          ToolOutcome.error => 'error',
          ToolOutcome.rejected => 'refused',
        };
        final body = outcome == ToolOutcome.rejected ? '${e.observation['reason'] ?? ''}' : e.text;
        out
          ..writeln('<details><summary>${call?.toolName ?? 'tool'} $label</summary>\n')
          ..writeln('```\n${_cap(body.trim(), resultCap)}\n```\n</details>\n');
      case ConversationFailure(:final message):
        out.writeln('> **Error:** $message\n');
      default:
        break;
    }
  }
  return out.toString();
}

DateTime? _time(HarnessEvent e) => switch (e.raw['timestamp']) {
  final String s => DateTime.tryParse(s),
  _ => null,
};

String _duration(Duration d) {
  if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inMilliseconds / 1000}s';
}

String _cap(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}\n… (${s.length - max} more characters)';
