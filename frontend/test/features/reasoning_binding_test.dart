import 'package:every_ai/features/code/harness/everyai/reasoning_binding.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> claude(String sig) => {
  'type': 'reasoning.text',
  'text': 'thinking',
  'signature': sig,
  'format': 'anthropic-claude-v1',
};
const gemini = {'type': 'reasoning.encrypted', 'data': 'g', 'format': 'google-gemini-v1'};

void main() {
  final seed = bindingSeed('anthropic/claude-opus-5.5', const [
    {'type': 'function', 'name': 'read'},
  ]);
  final system = {'role': 'system', 'content': 'sys'};
  final user = {'role': 'user', 'content': 'build it'};

  /// The reply a call made from [before] would be kept as.
  Map<String, Object?> reply(List<Map<String, Object?>> before, List<Object?> details) {
    final m = <String, Object?>{'role': 'assistant', 'content': '', 'reasoning_details': details};
    m[boundKey] = bindReasoning(before, seed).prefix;
    return m;
  }

  test('thinking goes back while everything before it is unchanged', () {
    final a = reply([system, user], [claude('S1')]);
    final sent = bindReasoning([
      system,
      user,
      a,
      {'role': 'tool', 'content': 'ok'},
    ], seed).messages;
    expect(sent[2]['reasoning_details'], [claude('S1')]);
    expect(sent.any((m) => m.containsKey(boundKey)), isFalse);
  });

  test('an edit before the block (cleared output, compaction) drops only Claude thinking', () {
    final a = reply([system, user], [claude('S1'), gemini]);
    final edited = {'role': 'user', 'content': 'build it (older output cleared)'};
    final sent = bindReasoning([system, edited, a], seed).messages;
    expect(sent[2]['reasoning_details'], [gemini]);
  });

  test('a fork or a model switch (another seed) drops it; unbound old messages drop it too', () {
    final a = reply([system, user], [claude('S1')]);
    final other = bindingSeed('anthropic/claude-sonnet-5.5', const []);
    expect(bindReasoning([system, user, a], other).messages[2].containsKey('reasoning_details'), isFalse);
    final legacy = {
      'role': 'assistant',
      'content': '',
      'reasoning_details': [claude('S0')],
    };
    expect(bindReasoning([system, user, legacy], seed).messages[2].containsKey('reasoning_details'), isFalse);
  });

  test('a later block survives when an earlier one was dropped the same way each call', () {
    final a = reply([system, user], [claude('S1')]);
    final edited = {'role': 'user', 'content': 'changed'};
    // After the edit, the next reply is made from what was actually sent.
    final first = bindReasoning([system, edited, a], seed);
    final b = <String, Object?>{
      'role': 'assistant',
      'content': '',
      'reasoning_details': [claude('S2')],
      boundKey: first.prefix,
    };
    final sent = bindReasoning([system, edited, a, b], seed).messages;
    expect(sent[2].containsKey('reasoning_details'), isFalse);
    expect(sent[3]['reasoning_details'], [claude('S2')]);
  });
}
