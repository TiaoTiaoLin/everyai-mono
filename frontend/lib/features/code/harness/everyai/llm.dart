// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../../models/domain/model_catalog.dart' show ModelId;
import '../../../settings/domain/byok_providers.dart' show ModelBilling;

/// What a tool call being written has streamed so far (the gateway's
/// progress notes, or the call's own deltas).
typedef ToolProgress = ({int index, String name, String path, int chars, int lines});

/// One model reply, assembled from the gateway's stream.
final class LlmReply {
  LlmReply({
    required this.text,
    required this.reasoning,
    required this.reasoningDetails,
    required this.toolCalls,
    required this.finishReason,
    this.promptTokens = 0,
    this.cachedTokens = 0,
    this.order = const [],
  });

  final String text;

  /// The reply in the order it was written: text pieces (String) and tool
  /// calls (their position in [toolCalls], int). Anthropic models talk
  /// between calls in one reply; this keeps that for the transcript.
  final List<Object> order;
  final String reasoning;

  /// OpenRouter's structured reasoning (signed thinking blocks), sent back on
  /// the assistant message so the next call can continue from it.
  final List<Map<String, Object?>> reasoningDetails;
  final List<LlmToolCall> toolCalls;
  final String finishReason;

  /// Input tokens of this call: how full the context is.
  final int promptTokens;

  /// Of [promptTokens], how many were read from the prompt cache.
  final int cachedTokens;

  /// The assistant message to keep in the history.
  Map<String, Object?> toMessage() => {
    'role': 'assistant',
    'content': text,
    if (reasoningDetails.isNotEmpty) 'reasoning_details': reasoningDetails,
    if (toolCalls.isNotEmpty) 'tool_calls': [for (final c in toolCalls) c.toJson()],
  };
}

final class LlmToolCall {
  LlmToolCall({required this.id, required this.name, required this.arguments});

  final String id;
  final String name;

  /// The raw JSON text the model wrote.
  final String arguments;

  /// The arguments, or null when they aren't a JSON object (cut off, say).
  Map<String, Object?>? get args {
    try {
      final v = jsonDecode(arguments.isEmpty ? '{}' : arguments);
      return v is Map<String, Object?> ? v : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

final class LlmError implements Exception {
  const LlmError(this.message, {this.status, this.retryable = false, this.retryAfter, this.afterToolCall = false});
  final String message;
  final int? status;

  /// A transient failure (overloaded, rate-limited, a dropped connection):
  /// the same request may succeed if sent again.
  final bool retryable;

  /// How long the server asked us to wait (`Retry-After`), if it said.
  final Duration? retryAfter;

  /// The stream broke after a tool call had started: sending the request
  /// again could write a different call, so it is not retried.
  final bool afterToolCall;

  @override
  String toString() => message;
}

/// HTTP statuses worth another try: timeouts, conflicts, rate limits,
/// server errors and Anthropic's 529 (overloaded).
const retryableStatuses = {408, 409, 425, 429, 500, 502, 503, 504, 529};

/// Words in a mid-stream error's message that mark it transient. Providers
/// behind OpenRouter often send only a message ("Rate limit exceeded: …
/// Please retry shortly", "The operation was aborted").
final _transientMessage = RegExp(
  r'rate.?limit|retry (shortly|later|again)|overloaded|temporarily|try again|timed? ?out|operation was aborted|'
  r'upstream (error|connect)|connection (reset|closed)',
  caseSensitive: false,
);

/// Whether a mid-stream `{"error": …}` is a transient one.
bool retryableStreamError(Map<String, Object?> e) {
  final type = '${e['type'] ?? ''}'.toLowerCase();
  final code = '${e['code'] ?? ''}';
  return type.contains('overloaded') ||
      type.contains('rate_limit') ||
      type.contains('timeout') ||
      retryableStatuses.contains(int.tryParse(code)) ||
      code == 'rate_limit_exceeded' ||
      _transientMessage.hasMatch('${e['message'] ?? ''}');
}

/// The wait a response asks for: `retry-after-ms`, else `Retry-After` in
/// seconds or as an HTTP date. Null when it doesn't say (or can't be read).
Duration? parseRetryAfter(Map<String, String> headers, {DateTime? now}) {
  String? header(String name) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == name) return e.value.trim();
    }
    return null;
  }

  if (header('retry-after-ms') case final ms?) {
    if (double.tryParse(ms) case final v? when v >= 0) return Duration(microseconds: (v * 1000).round());
  }
  final v = header('retry-after');
  if (v == null || v.isEmpty) return null;
  if (double.tryParse(v) case final s?) return s < 0 ? null : Duration(milliseconds: (s * 1000).round());
  final at = _parseHttpDate(v);
  if (at == null) return null;
  final d = at.difference((now ?? DateTime.now()).toUtc());
  return d.isNegative ? Duration.zero : d;
}

const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/// An RFC 1123 date ("Wed, 21 Oct 2026 07:28:00 GMT").
DateTime? _parseHttpDate(String s) {
  final m = RegExp(r'(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4}) (\d{2}):(\d{2}):(\d{2})').firstMatch(s);
  if (m == null) return null;
  final month = _months.indexOf(m[2]!.toLowerCase()) + 1;
  if (month == 0) return null;
  var year = int.parse(m[3]!);
  if (year < 100) year += 2000;
  return DateTime.utc(year, month, int.parse(m[1]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
}

/// How often and how patiently a model call is sent again after a
/// transient failure: exponential backoff from [base] to [cap] with
/// ±[jitter], or the server's `Retry-After` up to [maxRetryAfter].
final class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 8,
    this.base = const Duration(seconds: 1),
    this.cap = const Duration(seconds: 60),
    this.jitter = 0.25,
    this.maxRetryAfter = const Duration(minutes: 5),
  });

  /// Attempts in all, the first one included.
  final int maxAttempts;
  final Duration base;
  final Duration cap;
  final double jitter;
  final Duration maxRetryAfter;

  /// The wait after [failed] attempts failed, before the next one.
  Duration delay(int failed, {Duration? retryAfter, Random? random}) {
    if (retryAfter != null) return retryAfter > maxRetryAfter ? maxRetryAfter : retryAfter;
    final exp = base.inMicroseconds * pow(2, max(0, failed - 1));
    final capped = min(exp.toDouble(), cap.inMicroseconds.toDouble());
    final spread = 1 + jitter * (2 * (random ?? _random).nextDouble() - 1);
    return Duration(microseconds: (capped * spread).round());
  }

  static final _random = Random();
}

/// A retry about to happen, shown live in the transcript: [attempt] of
/// [max] starts after [delay].
typedef RetryNotice = ({int attempt, int max, Duration delay, String reason, int? status});

/// The wait between attempts, which the user can cut short ("Retry now").
final class RetryWait {
  Completer<void>? _now;

  /// Ends the current wait at once (nothing when none is going).
  void skip() {
    final c = _now;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> sleep(Duration d, {Future<void>? cancel}) async {
    final now = _now = Completer<void>();
    final timer = Timer(d, () {
      if (!now.isCompleted) now.complete();
    });
    unawaited(
      cancel?.then((_) {
        if (!now.isCompleted) now.complete();
      }),
    );
    await now.future;
    timer.cancel();
    if (identical(_now, now)) _now = null;
  }
}

/// Calls the EveryAI gateway (`POST {base}/chat/completions`, OpenAI-style,
/// streamed). The gateway meters by `X-EveryAI-Session`, adds prompt-cache
/// breakpoints, applies `X-EveryAI-Effort` and recovers cut-off replies.
final class GatewayClient {
  GatewayClient({required this.baseUrl, required this.apiKey, http.Client? client}) : _http = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final http.Client _http;

  Uri get _url => Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/chat/completions');

  /// With [model], the user's own key when that model bills to one
  /// (`ModelBilling`): read per call, so forks and model switches follow it.
  Map<String, String> _headers(String sessionTag, String? effort, {String? model}) => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'X-EveryAI-Session': sessionTag,
    'X-EveryAI-Effort': ?effort,
    if (model != null) ...ModelBilling.current.headersFor(ModelId(model)),
  };

  /// Streams one reply. [onText] and [onReasoning] get the deltas as they
  /// arrive; [cancel] completes to abandon the call.
  Future<LlmReply> complete({
    required String model,
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
    required String sessionTag,
    String? effort,
    int? maxTokens,
    String? toolChoice,
    void Function(String delta)? onText,
    void Function(String delta)? onReasoning,
    void Function(ToolProgress progress)? onToolProgress,
    Future<void>? cancel,
  }) async {
    final req = http.Request('POST', _url)
      ..headers.addAll(_headers(sessionTag, effort, model: model))
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'messages': messages,
        if (tools.isNotEmpty) 'tools': tools,
        'tool_choice': ?toolChoice,
        'max_tokens': ?maxTokens,
      });
    final http.StreamedResponse res;
    try {
      res = await _http.send(req);
    } on http.ClientException catch (e) {
      throw LlmError('Could not reach the model: ${e.message}', retryable: true);
    } on TimeoutException {
      throw const LlmError('The model call timed out.', retryable: true);
    }
    if (res.statusCode >= 300) {
      final body = await res.stream.bytesToString();
      throw _statusError(body, res.statusCode, res.headers);
    }
    // Once a tool call starts streaming, a broken stream is not retried.
    var toolStarted = false;
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final details = <int, Map<String, Object?>>{};
    final calls = <int, ({StringBuffer id, StringBuffer name, StringBuffer args})>{};
    // Text pieces and tool indexes, in the order they started.
    final order = <Object>[];
    final seenTools = <int>{};
    void textAt(String t) {
      if (order.isNotEmpty && order.last is String) {
        order.last = '${order.last}$t';
      } else {
        order.add(t);
      }
    }

    void toolAt(int index) {
      if (seenTools.add(index)) order.add(index);
    }

    var finish = '';
    var promptTokens = 0;
    var cachedTokens = 0;
    var cancelled = false;
    final lines = res.stream.transform(utf8.decoder).transform(const LineSplitter());
    final done = Completer<void>();
    late final StreamSubscription<String> sub;
    unawaited(
      cancel?.then((_) {
        cancelled = true;
        unawaited(sub.cancel());
        if (!done.isCompleted) done.complete();
      }),
    );
    sub = lines.listen(
      (line) {
        if (line.startsWith(': progress ')) {
          // The gateway holds tool calls until they are whole; these notes say what is being written.
          try {
            for (final t in jsonDecode(line.substring(11)) as List<Object?>) {
              if (t case {'index': final num i}) {
                final m = t as Map<String, Object?>;
                // Not toolStarted: the gateway holds the call until it is
                // whole, so nothing of it has reached the harness yet and a
                // retry is safe.
                toolAt(i.toInt());
                onToolProgress?.call((
                  index: i.toInt(),
                  name: m['name'] as String? ?? '',
                  path: m['path'] as String? ?? '',
                  chars: (m['chars'] as num?)?.toInt() ?? 0,
                  lines: (m['lines'] as num?)?.toInt() ?? 0,
                ));
              }
            }
          } on Object {
            // A note that doesn't parse is only a missed update.
          }
          return;
        }
        if (!line.startsWith('data:')) return;
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') return;
        final Object? json;
        try {
          json = jsonDecode(data);
        } on FormatException {
          return;
        }
        if (json is! Map<String, Object?>) return;
        if (json['error'] case final Map<String, Object?> e) {
          if (!done.isCompleted) {
            final code = e['code'];
            done.completeError(
              LlmError(
                '${e['message'] ?? e}',
                status: code is num ? code.toInt() : int.tryParse('${code ?? ''}'),
                retryable: retryableStreamError(e),
                afterToolCall: toolStarted,
              ),
            );
          }
          return;
        }
        if (json['usage'] case {'prompt_tokens': final num p}) promptTokens = p.toInt();
        if (json['usage'] case {'prompt_tokens_details': {'cached_tokens': final num c}}) cachedTokens = c.toInt();
        final choices = json['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) return;
        final choice = choices.first as Map<String, Object?>;
        if (choice['finish_reason'] case final String f when f.isNotEmpty) finish = f;
        final delta = choice['delta'];
        if (delta is! Map<String, Object?>) return;
        if (delta['content'] case final String c when c.isNotEmpty) {
          text.write(c);
          textAt(c);
          onText?.call(c);
        }
        final r = delta['reasoning'] ?? delta['reasoning_content'];
        if (r is String && r.isNotEmpty) {
          reasoning.write(r);
          onReasoning?.call(r);
        }
        if (delta['reasoning_details'] case final List<Object?> list) {
          for (final (i, item) in list.indexed) {
            if (item is! Map<String, Object?>) continue;
            mergeReasoningDetail(details, item, fallbackIndex: i);
          }
        }
        if (delta['tool_calls'] case final List<Object?> list) {
          for (final item in list) {
            if (item is! Map<String, Object?>) continue;
            final index = (item['index'] as num?)?.toInt() ?? calls.length;
            toolStarted = true;
            toolAt(index);
            final slot = calls.putIfAbsent(
              index,
              () => (id: StringBuffer(), name: StringBuffer(), args: StringBuffer()),
            );
            if (item['id'] case final String id when id.isNotEmpty) {
              slot.id
                ..clear()
                ..write(id);
            }
            if (item['function'] case final Map<String, Object?> f) {
              if (f['name'] case final String n when n.isNotEmpty) slot.name.write(n);
              if (f['arguments'] case final String a) slot.args.write(a);
            }
          }
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) {
          done.completeError(
            LlmError('The connection to the model dropped: $e', retryable: true, afterToolCall: toolStarted),
          );
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await done.future;
    if (cancelled) throw const LlmCancelled();
    final keys = calls.keys.toList()..sort();
    final position = {for (final (n, k) in keys.indexed) k: n};
    return LlmReply(
      order: [
        for (final o in order)
          if (o is String) o else ?position[o],
        // Calls no note announced go last, in order.
        for (final k in keys)
          if (!seenTools.contains(k)) position[k]!,
      ],
      text: text.toString(),
      reasoning: reasoning.toString(),
      reasoningDetails: [for (final k in details.keys.toList()..sort()) details[k]!],
      toolCalls: [
        for (final (n, k) in keys.indexed)
          LlmToolCall(
            id: calls[k]!.id.isEmpty ? 'call_${DateTime.now().microsecondsSinceEpoch}_$n' : calls[k]!.id.toString(),
            name: calls[k]!.name.toString(),
            arguments: calls[k]!.args.toString(),
          ),
      ],
      finishReason: finish,
      promptTokens: promptTokens,
      cachedTokens: cachedTokens,
    );
  }

  /// [complete], sent again after a transient failure ([LlmError.retryable])
  /// as long as no tool call had started streaming: the same request, so the
  /// cached prefix makes the retry cheap. Text that streamed before the
  /// failure is dropped: [onRetry] tells the caller (to clear it) before
  /// each wait, which [wait] lets the user cut short. [cancel] ends it all.
  Future<LlmReply> completeWithRetry({
    required String model,
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
    required String sessionTag,
    String? effort,
    int? maxTokens,
    String? toolChoice,
    void Function(String delta)? onText,
    void Function(String delta)? onReasoning,
    void Function(ToolProgress progress)? onToolProgress,
    Future<void>? cancel,
    RetryPolicy policy = const RetryPolicy(),
    void Function(RetryNotice notice)? onRetry,
    RetryWait? wait,
  }) => _retrying(
    () => complete(
      model: model,
      messages: messages,
      tools: tools,
      sessionTag: sessionTag,
      effort: effort,
      maxTokens: maxTokens,
      toolChoice: toolChoice,
      onText: onText,
      onReasoning: onReasoning,
      onToolProgress: onToolProgress,
      cancel: cancel,
    ),
    policy: policy,
    onRetry: onRetry,
    wait: wait,
    cancel: cancel,
  );

  Future<T> _retrying<T>(
    Future<T> Function() attempt, {
    required RetryPolicy policy,
    void Function(RetryNotice notice)? onRetry,
    RetryWait? wait,
    Future<void>? cancel,
  }) async {
    var cancelled = false;
    unawaited(cancel?.then((_) => cancelled = true));
    for (var n = 1; ; n++) {
      try {
        return await attempt();
      } on LlmError catch (e) {
        if (!e.retryable || e.afterToolCall || n >= policy.maxAttempts || cancelled) rethrow;
        final delay = policy.delay(n, retryAfter: e.retryAfter);
        onRetry?.call((attempt: n + 1, max: policy.maxAttempts, delay: delay, reason: e.message, status: e.status));
        await (wait ?? RetryWait()).sleep(delay, cancel: cancel);
        if (cancelled) throw const LlmCancelled();
      }
    }
  }

  /// A page through the gateway's safe fetcher (`POST {base}/fetch`): no local
  /// or private addresses, redirects checked, and only [allow]'s hosts when
  /// given. Returns the page's text, fenced as untrusted, or throws.
  Future<({String url, String text, int? nextOffset})> fetchPage(
    String url, {
    required String sessionTag,
    List<String>? allow,
    int offset = 0,
    int? maxChars,
  }) async {
    final res = await _http
        .post(
          Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/fetch'),
          headers: _headers(sessionTag, null),
          body: jsonEncode({'url': url, 'allow': ?allow, 'offset': offset, 'max_chars': ?maxChars}),
        )
        .timeout(const Duration(seconds: 60));
    final Object? v;
    try {
      v = jsonDecode(res.body);
    } on FormatException {
      throw LlmError('The fetch failed (${res.statusCode}).', status: res.statusCode);
    }
    if (v case {'error': final String e}) throw LlmError(e, status: res.statusCode);
    if (v case {'error': {'message': final String e}}) throw LlmError(e, status: res.statusCode);
    if (v case {'url': final String u, 'text': final String t}) {
      return (url: u, text: t, nextOffset: ((v as Map)['next_offset'] as num?)?.toInt());
    }
    throw LlmError('The fetch failed (${res.statusCode}).', status: res.statusCode);
  }

  /// Typed answers from the backend's fast decider (`/v1/aux/decide`):
  /// [questions] are `{id, kind: bool|choice|score, prompt, choices?}`; the
  /// result maps each id to true/false, a choice, 0–1, or "unsure". Throws
  /// [LlmError] when the call fails (callers treat that as unsure).
  Future<Map<String, Object?>> decide(
    String text,
    List<Map<String, Object?>> questions, {
    required String sessionTag,
    String job = 'script',
    String? instructions,
    Future<void>? cancel,
  }) async {
    final call = _http
        .post(
          Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/aux/decide'),
          headers: _headers(sessionTag, null),
          body: jsonEncode({'job': job, 'text': text, 'instructions': ?instructions, 'questions': questions}),
        )
        .timeout(const Duration(seconds: 60));
    final http.Response res;
    try {
      res = cancel == null
          ? await call
          : await Future.any([call, cancel.then<http.Response>((_) => throw const LlmCancelled())]);
    } on http.ClientException catch (e) {
      throw LlmError('Could not reach the decider: ${e.message}', retryable: true);
    } on TimeoutException {
      throw const LlmError('The decider timed out.', retryable: true);
    }
    if (res.statusCode >= 300) throw _statusError(res.body, res.statusCode, res.headers);
    final v = jsonDecode(res.body);
    final answers = v is Map<String, Object?> ? v['answers'] : null;
    if (answers is! List<Object?>) throw const LlmError('The decider sent an unreadable reply.');
    return {
      for (final a in answers.whereType<Map<String, Object?>>())
        if (a['id'] case final String id) id: a['value'] ?? 'unsure',
    };
  }

  /// A plain (not streamed) call, for search, the goal judge and
  /// compaction; with [retry], transient failures are tried again as in
  /// [completeWithRetry].
  Future<Map<String, Object?>> raw(
    Map<String, Object?> body, {
    required String sessionTag,
    RetryPolicy? retry,
    void Function(RetryNotice notice)? onRetry,
    RetryWait? wait,
    Future<void>? cancel,
  }) {
    Future<Map<String, Object?>> once() async {
      final http.Response res;
      try {
        res = await _http.post(
          _url,
          headers: _headers(sessionTag, null, model: body['model'] as String?),
          body: jsonEncode(body),
        );
      } on http.ClientException catch (e) {
        throw LlmError('Could not reach the model: ${e.message}', retryable: true);
      }
      if (res.statusCode >= 300) throw _statusError(res.body, res.statusCode, res.headers);
      final v = jsonDecode(res.body);
      if (v is! Map<String, Object?>) throw const LlmError('The model sent an unreadable reply.');
      return v;
    }

    if (retry == null) return once();
    return _retrying(once, policy: retry, onRetry: onRetry, wait: wait, cancel: cancel);
  }

  static LlmError _statusError(String body, int status, Map<String, String> headers) => LlmError(
    _errorText(body, status),
    status: status,
    retryable: retryableStatuses.contains(status),
    retryAfter: parseRetryAfter(headers),
  );

  static String _errorText(String body, int status) {
    try {
      final v = jsonDecode(body);
      if (v case {'error': {'message': final String m}}) return m;
      if (v case {'error': final String m}) return m;
    } on FormatException {
      // fall through
    }
    return 'The model call failed ($status): ${body.length > 300 ? '${body.substring(0, 300)}…' : body}';
  }

  void close() => _http.close();
}

/// The call was abandoned (Stop).
final class LlmCancelled implements Exception {
  const LlmCancelled();
}

/// Folds a streamed `reasoning_details` entry into [blocks]: entries with the
/// same index are one block, their `text`/`summary`/`data` concatenated and
/// other fields (type, signature, format, id) kept at their latest value
/// (as the gateway's own parser does).
void mergeReasoningDetail(Map<int, Map<String, Object?>> blocks, Map<String, Object?> item, {int fallbackIndex = 0}) {
  final index = (item['index'] as num?)?.toInt() ?? fallbackIndex;
  final block = blocks.putIfAbsent(index, () => <String, Object?>{});
  for (final MapEntry(:key, :value) in item.entries) {
    if (key == 'index') continue;
    if ((key == 'text' || key == 'summary' || key == 'data') && value is String) {
      block[key] = '${block[key] as String? ?? ''}$value';
    } else if (value != null) {
      block[key] = value;
    }
  }
}
