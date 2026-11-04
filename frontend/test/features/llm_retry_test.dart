import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One scripted response: a status, headers, and SSE lines; [dropAfter]
/// breaks the stream after that many lines.
typedef Scripted = ({int status, Map<String, String> headers, List<String> lines, int? dropAfter});

Scripted ok(List<String> lines) => (status: 200, headers: const {}, lines: lines, dropAfter: null);

String chunk(Map<String, Object?> delta) =>
    'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': delta},
      ],
    })}\n\n';

String textChunk(String t) => chunk({'content': t});

String toolChunk() => chunk({
  'tool_calls': [
    {
      'index': 0,
      'id': 'c1',
      'function': {'name': 'bash', 'arguments': '{"command":"ls"}'},
    },
  ],
});

/// A gateway that answers with [script] in order and counts requests.
({GatewayClient client, List<http.BaseRequest> requests}) gateway(List<Scripted> script) {
  final requests = <http.BaseRequest>[];
  final client = MockClient.streaming((req, _) async {
    requests.add(req);
    final s = script.removeAt(0);
    final c = StreamController<List<int>>();
    unawaited(() async {
      for (final (i, line) in s.lines.indexed) {
        if (s.dropAfter == i) {
          c.addError(http.ClientException('Connection reset by peer'));
          await c.close();
          return;
        }
        c.add(utf8.encode(line));
        await Future<void>.delayed(Duration.zero);
      }
      await c.close();
    }());
    return http.StreamedResponse(c.stream, s.status, headers: s.headers);
  });
  return (client: GatewayClient(baseUrl: 'http://gw/v1', apiKey: 'k', client: client), requests: requests);
}

const fast = RetryPolicy(base: Duration(milliseconds: 1), cap: Duration(milliseconds: 4));

Future<LlmReply> call(
  GatewayClient g, {
  List<RetryNotice>? notices,
  List<String>? text,
  RetryPolicy policy = fast,
  Future<void>? cancel,
}) => g.completeWithRetry(
  model: 'm',
  messages: const [
    {'role': 'user', 'content': 'hi'},
  ],
  tools: const [],
  sessionTag: 't',
  policy: policy,
  onRetry: notices?.add,
  onText: text?.add,
  cancel: cancel,
);

void main() {
  group('parseRetryAfter', () {
    test('reads seconds, milliseconds and HTTP dates', () {
      expect(parseRetryAfter({'Retry-After': '7'}), const Duration(seconds: 7));
      expect(parseRetryAfter({'retry-after-ms': '250', 'retry-after': '9'}), const Duration(milliseconds: 250));
      final now = DateTime.utc(2026, 10, 30, 12);
      expect(parseRetryAfter({'retry-after': 'Fri, 30 Oct 2026 12:00:20 GMT'}, now: now), const Duration(seconds: 20));
      expect(parseRetryAfter({'retry-after': 'soon'}), isNull);
      expect(parseRetryAfter(const {}), isNull);
    });
  });

  group('RetryPolicy', () {
    test('backs off exponentially with ±25% jitter, capped at 60 s', () {
      const p = RetryPolicy();
      final r = Random(1);
      for (final (n, base) in [(1, 1000), (2, 2000), (3, 4000), (7, 60000), (12, 60000)]) {
        final d = p.delay(n, random: r).inMilliseconds;
        expect(d, inInclusiveRange(base * 0.75, base * 1.25), reason: 'attempt $n');
      }
    });

    test('honours Retry-After up to five minutes', () {
      const p = RetryPolicy();
      expect(p.delay(1, retryAfter: const Duration(seconds: 30)), const Duration(seconds: 30));
      expect(p.delay(1, retryAfter: const Duration(hours: 1)), const Duration(minutes: 5));
    });
  });

  group('usage limits', () {
    Scripted failing(int status, Map<String, Object?> error) => (
      status: status,
      headers: const {},
      lines: [
        jsonEncode({'error': error}),
      ],
      dropAfter: null,
    );
    Future<LlmError> errorOf(Scripted s) async {
      try {
        await call(gateway([s]).client, policy: const RetryPolicy(maxAttempts: 1));
      } on LlmError catch (e) {
        return e;
      }
      fail('no error');
    }

    test('a 402 is a limit unless it is an in-flight budget; retrying is unchanged', () async {
      final credits = await errorOf(failing(402, {'message': 'Insufficient credits'}));
      expect((credits.usageLimit, credits.retryable), (true, false));
      final inFlight = await errorOf(
        failing(402, {
          'message': 'Busy',
          'metadata': {'limit_source': 'openrouter_in_flight_budget'},
        }),
      );
      expect(inFlight.usageLimit, isFalse);
    });

    test("Anthropic's low credit balance is a limit; 429 and 503 stay retryable, not limits", () async {
      final low = await errorOf(
        failing(400, {'message': 'Your credit balance is too low to access the Anthropic API.'}),
      );
      expect(low.usageLimit, isTrue);
      for (final status in [429, 503]) {
        final e = await errorOf(failing(status, {'message': 'Try again'}));
        expect((e.usageLimit, e.retryable), (false, true), reason: '$status');
      }
    });

    test('a mid-stream out-of-credits error is a limit', () {
      expect(usageLimitOfError({'message': 'Out of EveryAI credits', 'code': 'out_of_credits'}, null), isNotNull);
      expect(usageLimitOfError({'message': 'Rate limit exceeded', 'code': 429}, 429), isNull);
    });
  });

  group('completeWithRetry', () {
    test('a 529 with Retry-After is retried, then the reply comes through', () async {
      final g = gateway([
        (
          status: 529,
          headers: const {'retry-after-ms': '2'},
          lines: ['{"error":{"message":"Overloaded","type":"overloaded_error"}}'],
          dropAfter: null,
        ),
        ok([textChunk('Hello'), 'data: [DONE]\n\n']),
      ]);
      final notices = <RetryNotice>[];
      final reply = await call(g.client, notices: notices);
      expect(reply.text, 'Hello');
      expect(g.requests, hasLength(2));
      expect(notices.single.attempt, 2);
      expect(notices.single.max, 8);
      expect(notices.single.status, 529);
      expect(notices.single.delay, const Duration(milliseconds: 2));
    });

    test('a drop before any tool call is retried; the partial text is void', () async {
      final g = gateway([
        (status: 200, headers: const {}, lines: [textChunk('Hel'), textChunk('lo')], dropAfter: 1),
        ok([textChunk('Hello again'), 'data: [DONE]\n\n']),
      ]);
      final notices = <RetryNotice>[];
      final reply = await call(g.client, notices: notices);
      expect(reply.text, 'Hello again');
      expect(notices, hasLength(1));
    });

    test('a drop after a tool call started is an error, not a retry', () async {
      final g = gateway([
        (status: 200, headers: const {}, lines: [toolChunk(), textChunk('x')], dropAfter: 1),
        ok([textChunk('never'), 'data: [DONE]\n\n']),
      ]);
      await expectLater(
        call(g.client),
        throwsA(isA<LlmError>().having((e) => e.afterToolCall, 'afterToolCall', isTrue)),
      );
      expect(g.requests, hasLength(1));
    });

    test('a mid-stream overloaded error is retried', () async {
      final g = gateway([
        ok(['data: {"error":{"message":"Overloaded","type":"overloaded_error","code":529}}\n\n']),
        ok([textChunk('Fine'), 'data: [DONE]\n\n']),
      ]);
      expect((await call(g.client)).text, 'Fine');
    });

    test('a provider rate limit sent only as a message is retried', () async {
      final g = gateway([
        ok([
          'data: {"error":{"message":"Rate limit exceeded: new-account-rpm/google/gemini-3.8-flash. Please retry shortly."}}\n\n',
        ]),
        ok(['data: {"error":{"message":"The operation was aborted"}}\n\n']),
        ok([textChunk('Fine'), 'data: [DONE]\n\n']),
      ]);
      expect((await call(g.client)).text, 'Fine');
      expect(g.requests, hasLength(3));
    });

    test('an error while the gateway still holds a tool call is retried', () async {
      final g = gateway([
        ok([
          ': progress [{"index":0,"name":"write","path":"index.html","chars":40000,"lines":900}]\n\n',
          'data: {"error":{"message":"The operation was aborted"}}\n\n',
        ]),
        ok([toolChunk(), 'data: [DONE]\n\n']),
      ]);
      final reply = await call(g.client);
      expect(reply.toolCalls.single.name, 'bash');
    });

    test('an unknown error is not retried', () async {
      final g = gateway([
        ok(['data: {"error":{"message":"Invalid schema for function"}}\n\n']),
      ]);
      await expectLater(call(g.client), throwsA(isA<LlmError>().having((e) => e.retryable, 'retryable', isFalse)));
    });

    test('a 400 is not retried', () async {
      final g = gateway([
        (status: 400, headers: const {}, lines: ['{"error":{"message":"bad"}}'], dropAfter: null),
      ]);
      await expectLater(call(g.client), throwsA(isA<LlmError>().having((e) => e.status, 'status', 400)));
      expect(g.requests, hasLength(1));
    });

    test('gives up after the last attempt', () async {
      final g = gateway([
        for (var i = 0; i < 3; i++) (status: 503, headers: const {}, lines: ['{}'], dropAfter: null),
      ]);
      final notices = <RetryNotice>[];
      await expectLater(
        call(
          g.client,
          notices: notices,
          policy: const RetryPolicy(maxAttempts: 3, base: Duration(milliseconds: 1)),
        ),
        throwsA(isA<LlmError>()),
      );
      expect(g.requests, hasLength(3));
      expect([for (final n in notices) n.attempt], [2, 3]);
    });

    test('Stop during the wait ends it at once', () async {
      final g = gateway([
        (status: 503, headers: const {'retry-after': '60'}, lines: ['{}'], dropAfter: null),
      ]);
      final cancel = Completer<void>();
      final watch = Stopwatch()..start();
      final f = call(g.client, notices: [], cancel: cancel.future);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.complete();
      await expectLater(f, throwsA(isA<LlmCancelled>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('Retry now cuts the wait short', () async {
      final g = gateway([
        (status: 503, headers: const {'retry-after': '60'}, lines: ['{}'], dropAfter: null),
        ok([textChunk('Back'), 'data: [DONE]\n\n']),
      ]);
      final wait = RetryWait();
      final f = g.client.completeWithRetry(
        model: 'm',
        messages: const [],
        tools: const [],
        sessionTag: 't',
        policy: fast,
        wait: wait,
        onRetry: (_) => Timer(const Duration(milliseconds: 10), wait.skip),
      );
      expect((await f.timeout(const Duration(seconds: 5))).text, 'Back');
    });
  });

  group('transcript', () {
    RetryState retry() => HarnessEvent.decode({
      'kind': 'ConversationStateUpdateEvent',
      'id': 'r1',
      'key': 'retry',
      'value': {'attempt': 3, 'max': 8, 'delay_ms': 8000, 'reason': 'Overloaded', 'status': 529, 'until': 0},
    }) as RetryState;

    test('a retry drops the partial reply and shows until the next delta', () {
      final b = TranscriptBuilder()
        ..add(const StateChange(id: 's', raw: {}, executionStatus: ExecutionStatus.running, key: 'execution_status'))
        ..add(const StreamDelta(raw: {}, content: 'Partial', reasoning: ''));
      expect(b.snapshot.streaming, 'Partial');
      b.add(retry());
      expect(b.snapshot.streaming, isEmpty);
      expect(b.snapshot.retry?.attempt, 3);
      expect(b.snapshot.retry?.status, 529);
      b.add(const StreamDelta(raw: {}, content: 'Again', reasoning: ''));
      expect(b.snapshot.retry, isNull);
    });

    test('a failure or stop ends the retry row', () {
      final b = TranscriptBuilder()..add(retry());
      b.add(const StateChange(id: 's', raw: {}, executionStatus: ExecutionStatus.paused, key: 'execution_status'));
      expect(b.snapshot.retry, isNull);
    });
  });
}
