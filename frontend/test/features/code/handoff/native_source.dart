import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart' show claudeAction;
import 'package:every_ai/features/code/drivers/driver_events.dart' show stateEvent;
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/handoff/handoff.dart';
import 'package:every_ai/features/code/handoff/native_import.dart';
import 'package:every_ai/features/code/harness/events.dart';

// The conversation the spike imported (docs/research/batches/multi-harness/run5/i1.md), as two leads' stints: the
// EveryAI harness made hello.txt, then Claude Code ran `echo MANGO > bye.txt` and was cut off by its usage limit
// before the commit came back.

const cwd = '/work/repo';

ChatMessage user(String id, String text) => ChatMessage(id: id, raw: const {}, fromUser: true, text: text);
ChatMessage agent(String id, String text) => ChatMessage(id: id, raw: const {}, fromUser: false, text: text);

ActionCall call(String id, String tool, Map<String, Object?> action) =>
    ActionCall(id: id, raw: const {}, toolName: tool, toolCallId: 't$id', action: action);

/// Claude Code's call [name] as its driver maps it.
ActionCall claudeCall(String id, String name, Map<String, Object?> input) {
  final a = claudeAction(name, input);
  return call(id, name, {'kind': a.kind, ...a.args});
}

ToolResult result(String id, String text, {ToolOutcome outcome = ToolOutcome.ok}) => ToolResult(
  id: 'r$id',
  raw: const {},
  actionId: id,
  toolName: 'x',
  outcome: outcome,
  observation: {
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
);

List<HarnessEvent> everyaiStint() => [
  user('u1', modeNote(AgentMode.autoEdit, 'Please create hello.txt containing the word PINEAPPLE.')),
  call('c1', 'file_editor', {
    'kind': 'FileEditorAction',
    'command': 'create',
    'path': '$cwd/hello.txt',
    'file_text': 'PINEAPPLE\n',
  }),
  result('c1', 'File created successfully at: $cwd/hello.txt'),
  agent('a1', 'Created hello.txt with PINEAPPLE.'),
  stateEvent('s1', ExecutionStatus.finished),
];

List<HarnessEvent> claudeStint() => [
  user('u2', 'Now make bye.txt containing MANGO, then commit both files.'),
  claudeCall('c2', 'Bash', {'command': 'echo MANGO > bye.txt'}),
  result('c2', '(no output)'),
  claudeCall('c3', 'Bash', {'command': 'git add -A && git commit -m "Add files"'}),
  usageLimitEvent('l1', 'You hit your 5-hour limit.'),
  stateEvent('s2', ExecutionStatus.error),
];

List<HandoffStint> stints() => [
  (lead: 'EveryAI', conversationId: 'conv-1', events: everyaiStint()),
  (lead: 'Claude Code', conversationId: 'claude-1', events: claudeStint()),
];

Handoff handoffOf(List<HandoffStint> stints, {required String to}) => buildHandoff(
  [for (final s in stints) ...s.events],
  from: stints.last.lead == 'Claude Code' ? 'claude-code' : 'everyai',
  fromConversation: stints.last.conversationId,
  to: to,
  workingDir: cwd,
  now: DateTime.utc(2026, 11, 4),
  transcript: '.everyai/handoffs/x.md',
);

NativeImportSource source({
  List<HandoffStint>? from,
  String to = 'codex',
  String sessionTag = 'tag-1',
  String model = 'gpt-5.5-codex',
  String? effort,
  String dir = cwd,
}) {
  final s = from ?? stints();
  return NativeImportSource(
    stints: s,
    handoff: handoffOf(s, to: to),
    cwd: dir,
    title: 'Fruit files',
    sessionTag: sessionTag,
    model: model,
    effort: effort,
  );
}
