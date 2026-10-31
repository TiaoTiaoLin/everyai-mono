import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Claude's signed thinking (reasoning details with an `anthropic…` format)
/// is bound to the exact request it came from: the model, the tools and
/// every message before it. Replaying a block after any of that changed
/// (old tool output cleared, a compaction, an older picture dropped, a fork
/// with its own system prompt, a model switch) fails the whole call with
/// "Invalid signature in thinking block".
///
/// So each kept reply records [Bound.prefix], a hash of what the model saw
/// when it wrote it, under [boundKey]. [bindReasoning] recomputes the hash
/// for every assistant message as the request goes out and strips the
/// Claude details whose prefix changed (or was never recorded). Other
/// providers' details stay: Gemini needs its thought signatures back on the
/// current turn's tool calls, and they are not bound to the history.
const boundKey = '_bound';

typedef Bound = ({List<Map<String, Object?>> messages, String prefix});

/// The start of the hash: what besides the messages a signature covers.
String bindingSeed(String model, List<Map<String, Object?>> tools) =>
    sha1.convert(utf8.encode(jsonEncode([model, tools]))).toString();

/// [messages] ready to send (no [boundKey]; stale Claude thinking removed),
/// and the hash of all of them, to record on the reply they produce.
Bound bindReasoning(List<Map<String, Object?>> messages, String seed) {
  var hash = seed;
  final out = <Map<String, Object?>>[];
  for (final m in messages) {
    var msg = m;
    if (msg.containsKey(boundKey) || msg['reasoning_details'] != null) {
      final copy = Map.of(msg);
      final bound = copy.remove(boundKey);
      if (bound != hash) _stripClaude(copy);
      msg = copy;
    }
    out.add(msg);
    hash = sha1.convert(utf8.encode('$hash\n${jsonEncode(msg)}')).toString();
  }
  return (messages: out, prefix: hash);
}

/// Whether [message] carries Claude thinking that would need a binding.
bool hasClaudeThinking(Map<String, Object?> message) =>
    (message['reasoning_details'] as List<Object?>? ?? const []).any(_isClaude);

bool _isClaude(Object? d) => d is Map && '${d['format'] ?? ''}'.startsWith('anthropic');

void _stripClaude(Map<String, Object?> message) {
  final details = message['reasoning_details'];
  if (details is! List<Object?> || !details.any(_isClaude)) return;
  final rest = [
    for (final d in details)
      if (!_isClaude(d)) d,
  ];
  if (rest.isEmpty) {
    message.remove('reasoning_details');
  } else {
    message['reasoning_details'] = rest;
  }
}
