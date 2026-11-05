import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/subagents.dart' show forkAnswerReason, taskTool;
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/prompt_io.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/domain/bug_check.dart' show bugReviewSystem;
import 'package:every_ai/features/code/domain/transcript.dart' show isOutOfCredits, planApprovedReason;
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/harness/everyai/scrub.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// A stand-in for the gateway: answers each chat completion with the next
/// scripted reply (as an SSE stream) and keeps the requests.
final class FakeGateway {
  FakeGateway._(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  final replies = <Map<String, Object?>>[];
  final requests = <Map<String, Object?>>[];

  /// How long a streamed reply takes to start (a slow model call).
  var delay = Duration.zero;

  /// What a plain (not streamed) call answers; null: a compaction summary.
  String? plain;

  /// What `/aux/decide` answers, by question id ("unsure" for the rest).
  final decisions = <String, Object?>{};

  /// The decider's requests.
  final decided = <Map<String, Object?>>[];

  static Future<FakeGateway> start() async => FakeGateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  /// An error reply: HTTP [status] with [error] as the JSON body's `error`.
  void fail(int status, Map<String, Object?> error) => replies.add({'status': status, 'error': error});

  /// A reply with [text] and these tool calls (name, arguments).
  void reply({String text = '', List<(String, Map<String, Object?>)> calls = const []}) => replies.add({
    'text': text,
    'calls': [for (final (name, args) in calls) (name, jsonEncode(args))],
  });

  Future<void> _handle(HttpRequest req) async {
    final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, Object?>;
    if (req.uri.path.endsWith('/aux/decide')) {
      decided.add(body);
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'answers': [
            for (final q in (body['questions'] as List<Object?>).cast<Map<String, Object?>>())
              {'id': q['id'], 'value': decisions[q['id']] ?? 'unsure'},
          ],
        }),
      );
      await req.response.close();
      return;
    }
    requests.add(body);
    if (body['stream'] != true) {
      // A plain call: the compaction summary.
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content':
                    plain ??
                    '## Objective\nMake hello.py\n## Important details\nnone\n## Work state\nwrote it\n'
                        '## Next move\n1. Run it\n## Relevant files\n- hello.py',
              },
            },
          ],
        }),
      );
      await req.response.close();
      return;
    }
    await Future<void>.delayed(delay);
    final next = replies.isEmpty ? {'text': 'Done.', 'calls': const <(String, String)>[]} : replies.removeAt(0);
    if (next['status'] case final int status) {
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': next['error']}));
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType('text', 'event-stream');
    void chunk(Map<String, Object?> delta, {String? finish}) => req.response.write(
      'data: ${jsonEncode({
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': ?finish},
        ],
      })}\n\n',
    );
    final text = next['text']! as String;
    if (text.isNotEmpty) {
      chunk({'content': text.substring(0, text.length ~/ 2)});
      chunk({'content': text.substring(text.length ~/ 2)});
    }
    final calls = next['calls']! as List<(String, String)>;
    for (final (i, (name, args)) in calls.indexed) {
      chunk({
        'tool_calls': [
          {
            'index': i,
            'id': 'call_${requests.length}_$i',
            'function': {'name': name, 'arguments': ''},
          },
        ],
      });
      chunk({
        'tool_calls': [
          {
            'index': i,
            'function': {'arguments': args},
          },
        ],
      });
    }
    chunk({}, finish: calls.isEmpty ? 'stop' : 'tool_calls');
    req.response.write('data: {"usage":{"prompt_tokens":1234,"completion_tokens":5}}\n\n');
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// The app's side of the host: answers every call, keeping their names.
final class _HostCalls implements HostTools {
  final names = <String>[];

  @override
  Future<HostResult> call(HostCall call) async {
    names.add(call.name);
    return (text: '2 files changed', isError: false);
  }
}

void main() {
  late Directory tmp;
  late String work;
  late FakeGateway gateway;
  late EveryAIHarness harness;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('everyai-harness');
    work = '${tmp.path}/project';
    Directory(work).createSync();
    gateway = await FakeGateway.start();
    harness = EveryAIHarness(dataDir: () async => '${tmp.path}/data', gatewayKey: () async => 'sk-test');
  });
  tearDown(() async {
    await gateway.close();
    await tmp.delete(recursive: true);
  });

  SessionSpec spec(String first, {AgentMode mode = AgentMode.fullAuto, bool vision = false}) => SessionSpec(
    workingDir: work,
    vision: vision,
    model: 'anthropic/claude-sonnet-5.5',
    mode: mode,
    llmBaseUrl: gateway.baseUrl,
    llmApiKey: 'sk-test',
    sessionTag: 'tag-1',
    initialMessage: first,
    holdClientTools: true,
  );

  /// Collects [session]'s events and approves everything that waits, the way
  /// Full auto does; [answer] decides held client tools instead.
  Future<List<HarnessEvent>> drive(
    HarnessSession session, {
    String? Function(ActionCall call)? answer,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final events = <HarnessEvent>[];
    final done = Completer<void>();
    final open = <ActionCall>[];
    late StreamSubscription<HarnessEvent> sub;
    sub = session.events.listen((e) async {
      events.add(e);
      if (e is ActionCall) open.add(e);
      if (e is ToolResult) open.removeWhere((c) => c.id == e.actionId);
      if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation) {
        final held = open.where((c) => answer?.call(c) != null).toList();
        if (held.isNotEmpty) {
          await session.respond(accept: false, reason: answer!(held.first));
          await session.resume();
        } else {
          await session.respond(accept: true);
        }
      }
      if (e is StateChange &&
          (e.executionStatus == ExecutionStatus.finished || e.executionStatus == ExecutionStatus.error)) {
        if (!done.isCompleted) done.complete();
      }
    });
    await done.future.timeout(timeout);
    await sub.cancel();
    return events;
  }

  test('runs tools after approval and finishes; the history survives reopening', () async {
    gateway
      ..reply(
        text: 'Creating the file.',
        calls: [
          ('write', {'file_path': 'hello.py', 'content': 'print("hi")\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bash', {'command': 'python3 hello.py'}),
        ],
      )
      ..reply(text: 'It prints hi.');
    final session = await harness.start(spec('make hello.py'));
    final events = await drive(session);

    expect(File('$work/hello.py').readAsStringSync(), 'print("hi")\n');
    final results = events.whereType<ToolResult>().toList();
    expect(results, hasLength(2));
    expect(results.last.text, contains('hi'));
    final calls = events.whereType<ActionCall>().toList();
    expect(calls.first.actionKind, 'WriteFileAction');
    expect(calls.first.str('path'), '$work/hello.py');
    expect(calls.last.actionKind, 'TerminalAction');

    // The second request carries the tool result after the assistant's call.
    final second = gateway.requests[1]['messages']! as List<Object?>;
    expect((second[second.length - 1]! as Map)['role'], 'tool');
    expect((second[second.length - 2]! as Map)['tool_calls'], isNotNull);
    expect((second.first! as Map)['role'], 'system');

    final fresh = EveryAIHarness(dataDir: () async => '${tmp.path}/data', gatewayKey: () async => 'sk-test');
    final reopened = await fresh.attach(session.id);
    final replay = await reopened.events.take(3).toList();
    expect(replay.whereType<ChatMessage>().first.text, 'make hello.py');
  });

  test('the context parts are the system message as sent, then one schema per tool sent', () async {
    gateway.reply(text: 'Done.');
    final session = await harness.start(spec('look around'));
    await drive(session);
    final sent = gateway.requests.first;
    final system = (sent['messages']! as List<Object?>).first! as Map<String, Object?>;
    final parts = (session as HasContextParts).contextParts;
    // Byte for byte: the parts don't change the cached prefix.
    expect(parts.where((p) => p.kind.inPrompt).map((p) => p.text).join('\n\n'), system['content']);
    final tools = parts.where((p) => !p.kind.inPrompt).toList();
    expect(tools.map((p) => p.name), [
      for (final t in (sent['tools']! as List<Object?>).cast<Map<String, Object?>>()) (t['function']! as Map)['name'],
    ]);
    expect(tools.every((p) => p.kind == ContextKind.tools), isTrue);
  });

  group('usage limits', () {
    tearDown(() => EveryAISession.testRetryPolicy = null);

    test('out of EveryAI credits is a usage limit, not retried, and still reads as out of credits', () async {
      gateway.fail(402, {'message': 'Out of EveryAI credits', 'type': 'insufficient_quota', 'code': 'out_of_credits'});
      final events = await drive(await harness.start(spec('go')));
      final limit = events.map(usageLimitOf).nonNulls.single;
      expect(isOutOfCredits(limit.message), isTrue);
      expect(limit.resetsAt, isNull);
      expect(gateway.requests, hasLength(1));
    });

    test("a key's spent budget is a usage limit with its reset", () async {
      gateway.fail(403, {
        'message': 'Key limit exceeded',
        'code': 403,
        'metadata': {'limit_source': 'openrouter_key_limit', 'resets_at': '2026-11-05T00:00:00Z'},
      });
      final events = await drive(await harness.start(spec('go')));
      expect(events.map(usageLimitOf).nonNulls.single.resetsAt, DateTime.utc(2026, 11, 5));
    });

    test('a rate limit that outlasts the retries is a plain failure', () async {
      EveryAISession.testRetryPolicy = const RetryPolicy(maxAttempts: 2, base: Duration.zero, cap: Duration.zero);
      for (var i = 0; i < 2; i++) {
        gateway.fail(429, {'message': 'Rate limit exceeded', 'code': 429});
      }
      final events = await drive(await harness.start(spec('go')));
      expect(gateway.requests, hasLength(2));
      expect(events.whereType<ConversationFailure>().single.message, 'Rate limit exceeded');
      expect(events.map(usageLimitOf).nonNulls, isEmpty);
    });
  });

  test('a held question is answered inside the call and the agent keeps its turn', () async {
    gateway
      ..reply(
        calls: [
          (
            askUserQuestionTool,
            {
              'questions': [
                {
                  'question': 'Which colour?',
                  'header': 'Colour',
                  'options': [
                    {'label': 'Red', 'description': ''},
                    {'label': 'Blue', 'description': ''},
                  ],
                },
              ],
            },
          ),
        ],
      )
      ..reply(text: 'Going with blue.');
    final session = await harness.start(spec('paint it'));
    await drive(session, answer: (c) => c.toolName == askUserQuestionTool ? 'Colour: Blue' : null);

    final last = gateway.requests.last['messages']! as List<Object?>;
    final tool = last.lastWhere((m) => (m! as Map)['role'] == 'tool')! as Map;
    expect(tool['content'], 'Colour: Blue');
    // No extra user message: the answer came back as the call's result.
    expect(last.where((m) => (m! as Map)['role'] == 'user'), hasLength(1));
  });

  test('a fork starts from the parent\'s exact history, so the cached prefix is shared', () async {
    gateway
      ..reply(
        calls: [
          ('read', {'file_path': 'notes.txt'}),
        ],
      )
      ..reply(text: 'Read it.');
    File('$work/notes.txt').writeAsStringSync('one\n');
    final parent = await harness.start(spec('look at notes'));
    await drive(parent);
    final parentLast = gateway.requests.last['messages']! as List<Object?>;

    gateway.reply(text: 'Forked result.');
    final child = await harness.fork(parent.id, spec('Now count the lines.'));
    await drive(child);
    final forked = gateway.requests.last['messages']! as List<Object?>;
    // Everything the parent sent last, then its reply and the fork's directive.
    expect(jsonEncode(forked.take(parentLast.length).toList()), jsonEncode(parentLast));
    expect((forked.last! as Map)['content'], 'Now count the lines.');
  });

  test('a fork keeps the parent\'s tools; it cannot start subagents, and its questions wait for an answer', () async {
    gateway.reply(text: 'Parent done.');
    final parent = await harness.start(spec('hi'));
    await drive(parent);
    gateway
      ..reply(
        calls: [
          (taskTool, {'description': 'x', 'prompt': 'y'}),
        ],
      )
      ..reply(
        calls: [
          (
            askUserQuestionTool,
            {
              'questions': [
                {'question': 'Dark or light?', 'header': 'Theme', 'options': <Object?>[]},
              ],
            },
          ),
        ],
      )
      ..reply(text: 'Report.');
    final child = await harness.fork(parent.id, spec('do a thing'));
    // The orchestrator's answer comes back as the question's result.
    final events = await drive(
      child,
      answer: (c) => c.toolName == askUserQuestionTool ? forkAnswerReason('Dark.') : null,
    );
    final results = events.whereType<ToolResult>().toList();
    expect(results.first.text, contains('a fork cannot use run_subagent'));
    expect('${results.last.observation['reason']}', contains('Dark.'));
    expect(events.whereType<ChatMessage>().last.text, 'Report.');
    // Same tool list as the parent, so the cached prefix holds.
    expect(jsonEncode(gateway.requests.last['tools']), jsonEncode(gateway.requests.first['tools']));
  });

  test('past the threshold the history is compacted in place and the run carries on', () async {
    gateway
      ..reply(
        calls: [
          ('write', {'file_path': 'hello.py', 'content': 'print(1)\n'}),
        ],
      )
      ..reply(text: 'All done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'm',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'k',
        sessionTag: 't',
        initialMessage: 'make hello.py',
        // The fake reports 1234 input tokens per call: past 60% of 1000.
        maxInputTokens: 1000,
      ),
    );
    final events = await drive(session);
    final notice = events.whereType<ChatMessage>().where((m) => m.fromUser && m.text.contains('<everyai-compacted>'));
    expect(notice, hasLength(1));
    final last = gateway.requests.last['messages']! as List<Object?>;
    // System prompt, then the continuation message: the old turns are gone.
    expect(last, hasLength(2));
    expect((last[1]! as Map)['content'], contains('## Objective'));
  });

  test('compaction re-injects the todos, the files touched last and loaded skills, and keeps them on disk', () async {
    Directory('$work/skills/tidy').createSync(recursive: true);
    File('$work/skills/tidy/SKILL.md').writeAsStringSync('# Tidy\nAlways sort imports.\n');
    gateway
      ..reply(
        calls: [
          ('read', {'file_path': 'skills/tidy/SKILL.md'}),
          (
            'todo_write',
            {
              'todos': [
                {'content': 'Write hello.py', 'status': 'completed'},
                {'content': 'Run it', 'status': 'in_progress'},
              ],
            },
          ),
          ('write', {'file_path': 'hello.py', 'content': 'print("hello")\n'}),
        ],
      )
      ..reply(text: 'All done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'm',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'k',
        sessionTag: 't',
        initialMessage: 'make hello.py',
        maxInputTokens: 1000,
      ),
    );
    await drive(session);
    final last = gateway.requests.last['messages']! as List<Object?>;
    final carried = (last[1]! as Map)['content']! as String;
    expect(carried, contains('<todos>\n- [x] Write hello.py\n- [~] Run it\n</todos>'));
    expect(carried, contains('<file path="$work/hello.py">\nprint("hello")'));
    expect(carried, contains('Always sort imports.'));
    expect(carried.indexOf('<files>'), lessThan(carried.indexOf('<skills>')));
    final state = jsonDecode(File('${tmp.path}/data/everyai-sessions/${session.id}/state.json').readAsStringSync());
    expect((state as Map)['touched'], contains('$work/hello.py'));
    expect(state['skills'], ['$work/skills/tidy/SKILL.md']);
  });

  test('a GPT session gets apply_patch and its rules block; the patch lands as an edit', () async {
    File('$work/a.txt').writeAsStringSync('one\n');
    gateway
      ..reply(
        calls: [
          ('read', {'file_path': 'a.txt'}),
        ],
      )
      ..reply(
        calls: [
          ('apply_patch', {'patch': '*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+two\n*** End Patch'}),
        ],
      )
      ..reply(text: 'Done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'openai/gpt-6.1-sol',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'k',
        sessionTag: 't',
        initialMessage: 'change a.txt',
      ),
    );
    final events = await drive(session);
    expect(File('$work/a.txt').readAsStringSync(), 'two\n');
    final first = gateway.requests.first;
    final tools = [for (final t in first['tools']! as List) ((t as Map)['function'] as Map)['name']];
    expect(tools, contains('apply_patch'));
    expect(tools, isNot(contains('edit')));
    final system = ((first['messages']! as List).first as Map)['content']! as String;
    expect(system, contains('<MODEL-NOTES>'));
    expect(system.indexOf('<HARNESS>'), lessThan(system.indexOf('<MODEL-NOTES>')));
    expect(events.whereType<ActionCall>().last.actionKind, 'ApplyPatchAction');
  });

  test('a message sent right after a stop (Option-Enter) runs instead of being dropped', () async {
    gateway
      ..delay = const Duration(milliseconds: 600)
      ..reply(text: 'Building the old thing.')
      ..reply(text: 'Doing the new thing.');
    final session = await harness.start(spec('build the old thing'));
    final run = drive(session);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    gateway.delay = Duration.zero;
    // What steer does: stop the run, then send at once.
    await session.interrupt();
    await session.send('do the new thing instead');
    final events = await run;
    final last = gateway.requests.last['messages']! as List;
    expect(jsonEncode(last), contains('do the new thing instead'));
    expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.finished);
  });

  test('a Claude session keeps edit and write and gets no rules block', () async {
    gateway.reply(text: 'Hi.');
    final session = await harness.start(spec('hi'));
    await drive(session);
    final first = gateway.requests.first;
    final tools = [for (final t in first['tools']! as List) ((t as Map)['function'] as Map)['name']];
    expect(tools, containsAll(['edit', 'write']));
    expect(((first['messages']! as List).first as Map)['content'], isNot(contains('<MODEL-NOTES>')));
  });

  test('monitor wakes when a background shell prints the line', () async {
    final shell = SessionShell(root: work, sessionTag: 't', scratchDir: '${tmp.path}/sh');
    final runner = ToolRunner(
      root: work,
      shell: shell,
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
      sessionTag: 't',
    );
    final started = await runner.run('bash', {
      'command': 'sleep 0.3; echo server ready; sleep 30',
      'run_in_background': true,
    });
    final id = started.observation['shell_id']! as String;
    final watch = Stopwatch()..start();
    final out = await runner.run('monitor', {'shell_id': id, 'until': 'ready', 'timeout_ms': 20000});
    expect(out.text, contains('Matched: server ready'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    await shell.killAll();
  });

  test('the same web search runs once per session, even from forks at the same time', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': '',
                'annotations': [
                  {
                    'url_citation': {'url': 'https://developer.mozilla.org/a', 'title': 'A', 'content': 'about a'},
                  },
                ],
              },
            },
          ],
        }),
        200,
      );
    });
    ToolRunner runner(String tag) => ToolRunner(
      root: work,
      shell: SessionShell(root: work, sessionTag: tag, scratchDir: '${tmp.path}/sh-$tag'),
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: '', client: client),
      sessionTag: tag,
    );
    final parent = runner('search-1'), fork = runner('search-1');
    final both = await Future.wait([
      parent.run('web_search', {'query': 'WebGL  game loop'}),
      fork.run('web_search', {'query': 'webgl game loop'}),
    ]);
    expect(calls, 1);
    expect(both.map((o) => o.text), everyElement(contains('developer.mozilla.org/a')));
    expect(both.where((o) => o.text.contains('repeated="true"')), hasLength(1));
    // Another session pays for its own.
    await runner('search-2').run('web_search', {'query': 'webgl game loop'});
    expect(calls, 2);
  });

  test("a fork's tools read the parent's paths as its own copy's", () async {
    final copy = Directory('${tmp.path}/copy')..createSync();
    final shell = SessionShell(root: copy.path, sessionTag: 't', scratchDir: '${tmp.path}/sh2');
    final runner = ToolRunner(
      root: copy.path,
      shell: shell,
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
      sessionTag: 't',
      pathMap: {work: copy.path},
    );
    await runner.run('write', {'file_path': '$work/game.js', 'content': 'x'});
    expect(File('${copy.path}/game.js').existsSync(), isTrue);
    expect(File('$work/game.js').existsSync(), isFalse);
    final out = await runner.run('bash', {'command': 'ls $work; echo ${work}2'});
    expect(out.text, contains('game.js'));
    // Only whole folder names are mapped.
    expect(out.text, contains('${work}2'));
    await shell.killAll();
  });

  test("a fork's write to the parent's scratch is judged on its own copy's path, and runs in Ask", () async {
    final copy = Directory('${tmp.path}/copy')..createSync();
    gateway
      ..reply(
        calls: [
          ('write', {'file_path': '$work/.everyai/scratch/probe.py', 'content': 'print(1)'}),
        ],
      )
      ..reply(text: 'Done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: copy.path,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.ask,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-1',
        initialMessage: 'probe',
        pathMap: {work: copy.path},
      ),
    );
    final events = await drive(session);
    final write = events.whereType<ActionCall>().single;
    expect(write.str('path'), '${copy.path}/.everyai/scratch/probe.py');
    // The model's own words stay as it sent them.
    expect(write.raw['tool_call'].toString(), contains('$work/.everyai/scratch/probe.py'));
    expect(PermissionPolicy(workingDir: copy.path).decide(write, AgentMode.ask).verdict, Verdict.allow);
    expect(File('${copy.path}/.everyai/scratch/probe.py').existsSync(), isTrue);
  });

  test('cd carries over between commands and a timeout kills the command', () async {
    Directory('$work/sub').createSync();
    final shell = SessionShell(root: work, sessionTag: 't', scratchDir: '${tmp.path}/sh');
    await shell.run('cd sub', timeout: const Duration(seconds: 10));
    final pwd = await shell.run('pwd', timeout: const Duration(seconds: 10));
    expect(pwd.output.trim(), endsWith('/sub'));
    final slow = await shell.run('sleep 20', timeout: const Duration(seconds: 1));
    expect(slow.timedOut, isTrue);
  });

  test('the scratch folders are kept out of git, once', () async {
    final repo = Directory.systemTemp.createTempSync('exclude');
    addTearDown(() => repo.deleteSync(recursive: true));
    await Process.run('git', ['init', '-q'], workingDirectory: repo.path);
    await excludeScratch(repo.path);
    await excludeScratch(repo.path);
    final exclude = File('${repo.path}/.git/info/exclude').readAsStringSync();
    expect('.everyai/scratch/'.allMatches(exclude).length, 1);
    Directory('${repo.path}/.everyai/scratch').createSync(recursive: true);
    File('${repo.path}/.everyai/scratch/x.txt').writeAsStringSync('x');
    final status = await Process.run('git', ['status', '--porcelain'], workingDirectory: repo.path);
    expect(status.stdout, isEmpty);
  });

  test('Full auto never asks, edits outside the project included', () {
    const policy = PermissionPolicy(workingDir: '/work');
    ActionCall edit(String path) => HarnessEvent.decode({
      'kind': 'ActionEvent',
      'id': 'e',
      'tool_name': 'write',
      'action': {'kind': 'FileEditorAction', 'command': 'create', 'path': path, 'file_text': 'x'},
    }) as ActionCall;
    expect(policy.decide(edit('/work/a.txt'), AgentMode.fullAuto).verdict, Verdict.allow);
    expect(policy.decide(edit('/etc/hosts'), AgentMode.fullAuto).verdict, Verdict.allow);
    expect(policy.decide(edit('/etc/hosts'), AgentMode.ask).verdict, Verdict.ask);
  });

  test('reading an image shows the picture to a vision model, after the tool results', () async {
    final pic = img.Image(width: 2400, height: 1200);
    img.fill(pic, color: img.ColorRgb8(200, 30, 30));
    File('$work/shot.png').writeAsBytesSync(img.encodePng(pic));
    gateway
      ..reply(
        calls: [
          ('read', {'file_path': 'shot.png'}),
        ],
      )
      ..reply(text: 'It is red.');
    final session = await harness.start(spec('look at shot.png', vision: true));
    await drive(session);
    final second = gateway.requests[1]['messages']! as List<Object?>;
    final tool = second.lastWhere((m) => (m! as Map)['role'] == 'tool')! as Map;
    expect(tool['content'], contains('attached below'));
    final last = second.last! as Map;
    expect(last['role'], 'user');
    final parts = last['content']! as List<Object?>;
    final url = ((parts[1]! as Map)['image_url']! as Map)['url']! as String;
    // 2400 px wide is shrunk to 1568 and re-encoded.
    expect(url, startsWith('data:image/jpeg;base64,'));
    final back = img.decodeJpg(base64Decode(url.substring(url.indexOf(',') + 1)))!;
    expect(back.width, 1568);
    await session.close();
  });

  test("reading an image without vision says the model can't see it", () async {
    File('$work/shot.png').writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));
    gateway
      ..reply(
        calls: [
          ('read', {'file_path': 'shot.png'}),
        ],
      )
      ..reply(text: 'ok');
    final session = await harness.start(spec('look'));
    final events = await drive(session);
    expect(events.whereType<ToolResult>().single.text, contains("can't view images"));
    await session.close();
  });

  test('MCP servers over stdio give the agent their tools, images included', () async {
    final server = File('$work/fake_mcp.py')
      ..writeAsStringSync(r'''
import json, sys
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m: continue
    meth = m["method"]
    if meth == "initialize": r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake"}}
    elif meth == "tools/list": r = {"tools": [{"name": "browser_take_screenshot", "description": "Screenshot the page", "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}}}]}
    elif meth == "tools/call": r = {"content": [{"type": "text", "text": "shot of " + m["params"]["arguments"].get("url", "")}, {"type": "image", "data": PNG, "mimeType": "image/png"}]}
    else: r = {}
    print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
''');
    gateway
      ..reply(
        calls: [
          ('browser_take_screenshot', {'url': 'http://localhost:3000'}),
        ],
      )
      ..reply(text: 'Looks right.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-1',
        initialMessage: 'check the page',
        vision: true,
        mcpConfig: {
          'fake': {
            'command': 'python3',
            'args': [server.path],
          },
        },
      ),
    );
    final events = await drive(session);
    final first = gateway.requests.first;
    final names = [for (final t in first['tools']! as List<Object?>) ((t! as Map)['function']! as Map)['name']];
    expect(names, contains('browser_take_screenshot'));
    final call = events.whereType<ActionCall>().single;
    expect(call.actionKind, 'MCPToolAction');
    expect(events.whereType<ToolResult>().single.text, contains('shot of http://localhost:3000'));
    final second = gateway.requests[1]['messages']! as List<Object?>;
    final last = second.last! as Map;
    expect(jsonEncode(last['content']), contains('data:image/png;base64,'));
    await session.close();
  });

  test("a briefed session reaches the app's host as everyai__ tools, in place of its own memory", () async {
    final host = createHostServer();
    addTearDown(host.stop);
    final tools = _HostCalls();
    final token = await host.mint('child', tools, only: workflowHostTools);
    gateway
      ..reply(calls: [('everyai__diff_stats', <String, Object?>{})])
      ..reply(text: 'Done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-1',
        initialMessage: 'fix the bug',
        // A workflow agent: a child, so no client tools of its own.
        subagent: true,
        briefing: DriverBriefing(mcpUrl: '${token.url}', mcpToken: token.token),
      ),
    );
    final events = await drive(session);
    final names = [
      for (final t in gateway.requests.first['tools']! as List<Object?>) ((t! as Map)['function']! as Map)['name'],
    ];
    expect(names, containsAll(['everyai__bug_check', 'everyai__check', 'everyai__diff_stats']));
    // No memory of its own or the host's: it reads it in its prompt, and the lead decides what is kept.
    expect(names.where((n) => '$n'.contains('memory')), isEmpty);
    expect(names.where((n) => '$n'.contains('fork') || '$n'.contains('run_workflow')), isEmpty);
    final call = events.whereType<ActionCall>().single;
    expect(call.actionKind, 'MCPToolAction');
    expect(call.toolName, 'everyai__diff_stats');
    expect(tools.names, ['diff_stats']);
    expect(events.whereType<ToolResult>().single.text, contains('2 files changed'));
    // The token lives in memory only.
    final spec = File('${tmp.path}/data/everyai-sessions/${session.id}/spec.json').readAsStringSync();
    expect(spec, isNot(contains(token.token)));
    await session.close();
  });

  test('a workflow agent reopened after a restart gets its new host, and never its own memory', () async {
    final host = createHostServer();
    addTearDown(host.stop);
    final tools = _HostCalls();
    final old = await host.mint('child', tools, only: workflowHostTools);
    gateway.reply(text: 'Reproduced.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-1',
        initialMessage: 'fix the bug',
        subagent: true,
        briefing: DriverBriefing(mcpUrl: '${old.url}', mcpToken: old.token),
      ),
    );
    await drive(session);
    await session.close();
    await host.revoke(old.token);
    List<Object?> toolNames() => [
      for (final t in gateway.requests.last['tools']! as List<Object?>) ((t! as Map)['function']! as Map)['name'],
    ];
    EveryAIHarness app() => EveryAIHarness(dataDir: () async => '${tmp.path}/data', gatewayKey: () async => 'sk-test');

    // With a fresh token: the host's tools again.
    final fresh = await host.mint('child', tools, only: workflowHostTools);
    gateway
      ..reply(calls: [('everyai__diff_stats', <String, Object?>{})])
      ..reply(text: 'Verified.');
    final reopened = await app().attachBriefed(
      session.id,
      DriverBriefing(mcpUrl: '${fresh.url}', mcpToken: fresh.token),
    );
    // Not drive: the replayed history ends finished already.
    Future<void> carryOn(HarnessSession s, String last) async {
      final approve = s.events.listen((e) {
        if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation) {
          unawaited(s.respond(accept: true));
        }
      });
      final said = s.events.firstWhere((e) => e is ChatMessage && !e.fromUser && e.text == last);
      await s.send('Carry on');
      await said.timeout(const Duration(seconds: 20));
      await approve.cancel();
    }

    await carryOn(reopened, 'Verified.');
    expect(toolNames(), contains('everyai__diff_stats'));
    expect(toolNames(), isNot(contains('memory')));
    expect(tools.names, ['diff_stats']);
    await reopened.close();

    // Without one (no host could be made): still no memory tool of its own.
    gateway.reply(text: 'Done.');
    final bare = await app().attach(session.id);
    await carryOn(bare, 'Done.');
    expect(toolNames(), isNot(contains('memory')));
    expect(toolNames().where((n) => '$n'.startsWith('everyai__')), isEmpty);
    await bare.close();
  });

  test('without a briefing a session keeps its own memory and has no everyai tools', () async {
    gateway.reply(text: 'Done.');
    final session = await harness.start(spec('hello'));
    await drive(session);
    final names = [
      for (final t in gateway.requests.first['tools']! as List<Object?>) ((t! as Map)['function']! as Map)['name'],
    ];
    expect(names, contains('memory'));
    expect(names.where((n) => '$n'.startsWith('everyai__')), isEmpty);
    await session.close();
  });

  group('applyEdit', () {
    test('replaces an exact, unique match', () {
      final r = applyEdit('a\nb\nc\n', 'b\n', 'B\n');
      expect(r.text, 'a\nB\nc\n');
    });

    test('refuses an ambiguous match unless replace_all', () {
      expect(applyEdit('x\nx\n', 'x', 'y').error, contains('2 places'));
      expect(applyEdit('x\nx\n', 'x', 'y', replaceAll: true).text, 'y\ny\n');
    });

    test('matches lines whose indentation is off', () {
      final r = applyEdit('def f():\n    return 1\n', 'def f():\n  return 1', 'def f():\n    return 2');
      expect(r.text, 'def f():\n    return 2\n');
    });
  });

  test('the environment block warns when pip and python3 are different Pythons', () {
    final block = formatEnvironment(
      workingDir: '/p',
      shell: '/bin/zsh',
      today: DateTime(2026, 10, 30),
      facts: {
        'which.python3': '/opt/homebrew/bin/python3',
        'which.pip': '/Users/a/Library/Python/3.9/bin/pip',
        'python3.version': '3.14.0 /opt/homebrew/bin/python3',
        'python3.pip': 'pip 25.2 from /opt/homebrew/lib/python3.14/site-packages/pip (python 3.14)',
        'pip.version': 'pip 21.2 from /Users/a/Library/Python/3.9/lib/python/site-packages/pip (python 3.9)',
      },
    );
    expect(block, contains('`pip` installs into Python 3.9 but `python3` is Python 3.14'));
    expect(block, contains('python3 -m pip'));
  });

  test('a command that starts by sleeping is a wait a message can cut short', () {
    expect(isWaitCommand('sleep 240; ls -la *.md'), isTrue);
    expect(isWaitCommand('  sleep 5 && cat out.txt'), isTrue);
    expect(isWaitCommand('sleep 1.5'), isTrue);
    expect(isWaitCommand('npm test; sleep 5'), isFalse);
    expect(isWaitCommand('sleepy --fast'), isFalse);
  });

  test('a research job has no shell, writes only its notes, reads no secrets, and stays on its sites', () async {
    File('$work/.env').writeAsStringSync('API_TOKEN=supersecretvalue123\n');
    final shell = SessionShell(root: work, sessionTag: 't', scratchDir: '${tmp.path}/sh-r');
    final runner = ToolRunner(
      root: work,
      shell: shell,
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: 'sk-eai-test-key-000000'),
      sessionTag: 't',
      researchSites: const ['github.com'],
    );
    expect((await runner.run('bash', {'command': 'echo hi'})).text, contains('no shell'));
    expect(
      (await runner.run('write', {'file_path': '$work/main.c', 'content': 'x'})).text,
      contains('only their notes'),
    );
    final notes = await runner.run('write', {
      'file_path': '$work/.everyai/scratch/research/http.md',
      'content': '# notes',
    });
    expect(notes.isError, isFalse);
    expect((await runner.run('read', {'file_path': '$work/.env'})).text, contains('secrets'));
    expect(
      (await runner.run('web_fetch', {'url': 'https://example.com/x'})).text,
      contains('not on the research sites'),
    );
    // The .env value can't leave in a URL, even on an allowed site.
    final leak = await runner.run('web_fetch', {'url': 'https://github.com/search?q=supersecretvalue123'});
    expect(leak.text, contains('secret'));
    await shell.killAll();
  });

  test('the scrubber catches key shapes and secret-named env values, and lets ordinary URLs through', () {
    final s = Scrubber(env: {'OPENAI_API_KEY': 'abcd1234efgh', 'USER': 'xuckless', 'HOME': '/Users/x'});
    expect(s.leak('https://github.com/xuckless/repo/commit/${'a' * 40}'), isNull);
    expect(s.leak('https://x.io/?k=abcd1234efgh'), isNotNull);
    expect(s.leak('https://x.io/?k=abcd1234%65fgh'), isNotNull);
    expect(s.leak('q=ghp_${'A' * 30}'), 'a GitHub token');
    expect(s.leak('q=sk-${'a' * 30}'), 'an API key');
    expect(s.leak('AKIAABCDEFGHIJKLMNOP'), 'an AWS key');
    expect(hostAllowed('unix.stackexchange.com', ['*.stackexchange.com']), isTrue);
    expect(hostAllowed('evilgithub.com', ['github.com']), isFalse);
    expect(secretPath('/Users/x/.ssh/id_ed25519'), isTrue);
    expect(secretPath('/p/.env.example'), isFalse);
  });

  test('Bug fix: the harness runs the repro itself, refuses a fake fix, and verifies the real one', () async {
    File('$work/calc.sh').writeAsStringSync('echo \$((2 + 2 + 1))\n');
    const repro = 'test "\$(sh calc.sh)" = 4';
    gateway
      ..reply(
        calls: [
          ('bug_check', {'action': 'reproduced', 'command': 'true'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'reproduced', 'command': repro}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'triage', 'kind': 'simple', 'why': 'An off-by-one in calc.sh.'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': '.everyai/scratch/plan.md', 'content': '# Remove the + 1'}),
        ],
      )
      ..reply(
        calls: [
          ('present_plan', {'plan': '# Remove the + 1'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(
        calls: [
          ('read', {'file_path': 'calc.sh'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc.sh', 'content': 'echo \$((2 + 2))\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(text: 'Fixed: calc.sh added one too many; the repro passes.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-bug',
        initialMessage: 'calc.sh prints 5 for 2 + 2',
        holdClientTools: true,
        bugCheck: true,
      ),
    );
    final events = await drive(session, answer: (c) => c.toolName == 'present_plan' ? planApprovedReason : null);
    final results = events.whereType<ToolResult>().map((r) => r.text).toList();
    expect(results[0], startsWith('Not reproduced'));
    expect(results[1], startsWith('Reproduced'));
    expect(results.where((r) => r.startsWith('Still failing')), hasLength(1), reason: 'verifying before the fix fails');
    expect(results.last, startsWith('Verified'));
    // No phases any more: the harness adds no notes of its own, and remembers the repro for later checks.
    expect(events.whereType<ChatMessage>().where((m) => m.fromUser), hasLength(1));
    final dir = '${tmp.path}/data/everyai-sessions/${session.id}';
    expect(jsonDecode(File('$dir/bug_check.json').readAsStringSync()), containsPair('repro_command', repro));
    final tools = (gateway.requests.first['tools']! as List).map((t) => ((t as Map)['function'] as Map)['name']);
    expect(tools, contains('bug_check'));
    // The approved plan is kept for compaction to re-inject.
    final state = jsonDecode(File('$dir/state.json').readAsStringSync());
    expect((state as Map)['approved_plan'], startsWith('# '));
  });

  test('Bug fix: a repro refused as another failure goes to a second model; one that only fails on '
      'something else after the fix verifies', () async {
    File('$work/calc.sh').writeAsStringSync('echo \$((2 + 2 + 1))\n');
    File('$work/check.sh').writeAsStringSync('test "\$(sh calc.sh)" = 4 || exit 1\ntest -f setup.done\n');
    gateway.decisions['shows'] = 'other';
    gateway.plain = '{"verdict": "accept", "reason": "The output is the wrong sum the report describes."}';
    gateway
      ..reply(
        calls: [
          ('bug_check', {'action': 'reproduced', 'command': 'sh check.sh'}),
        ],
      )
      ..reply(
        calls: [
          (
            'bug_check',
            {
              'action': 'review',
              'claim': 'reproduced',
              'command': 'sh check.sh',
              'evidence': 'It exits 1 on the sum check, the bug.',
            },
          ),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'triage', 'kind': 'simple', 'why': 'Off by one.'}),
        ],
      )
      ..reply(
        calls: [
          ('present_plan', {'plan': '# Remove the + 1'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc.sh', 'content': 'echo \$((2 + 2))\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(text: 'Fixed; setup.done is missing here, an older failure.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-bug3',
        initialMessage: 'calc.sh prints 5 for 2 + 2',
        holdClientTools: true,
        bugCheck: true,
        reviewModel: 'openai/gpt-6.1-sol',
      ),
    );
    final events = await drive(session, answer: (c) => c.toolName == 'present_plan' ? planApprovedReason : null);
    final results = events.whereType<ToolResult>().map((r) => r.text).toList();
    expect(results[0], allOf(startsWith('Not reproduced'), contains('bug_check review')));
    expect(results[1], startsWith('Accepted by review (openai/gpt-6.1-sol)'));
    expect(results.last, allOf(startsWith('Verified'), contains('no longer on this bug')));
    final review = gateway.requests.firstWhere((r) => r['stream'] != true && r['model'] == 'openai/gpt-6.1-sol');
    expect(((review['messages']! as List).first as Map)['content'], bugReviewSystem);
  });

  test('Bug fix: a fix that edits the repro test is refused; adding a test beside it is fine', () async {
    File('$work/calc.sh').writeAsStringSync('echo \$((2 + 2 + 1))\n');
    File('$work/calc_test.sh').writeAsStringSync('test "\$(sh calc.sh)" = 4\n');
    gateway
      ..reply(
        calls: [
          ('bug_check', {'action': 'reproduced', 'command': 'sh calc_test.sh'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'triage', 'kind': 'simple', 'why': 'Off by one.'}),
        ],
      )
      ..reply(
        calls: [
          ('present_plan', {'plan': '# Remove the + 1'}),
        ],
      )
      ..reply(
        calls: [
          ('read', {'file_path': 'calc_test.sh'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc_test.sh', 'content': 'exit 0\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc_test.sh', 'content': 'test "\$(sh calc.sh)" = 4\ntest 1 = 1\n'}),
        ],
      )
      ..reply(
        calls: [
          ('read', {'file_path': 'calc.sh'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc.sh', 'content': 'echo \$((2 + 2))\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(text: 'Fixed.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-bug2',
        initialMessage: 'calc.sh prints 5 for 2 + 2',
        holdClientTools: true,
        bugCheck: true,
      ),
    );
    final events = await drive(session, answer: (c) => c.toolName == 'present_plan' ? planApprovedReason : null);
    final results = events.whereType<ToolResult>().map((r) => r.text).toList();
    expect(results.first, startsWith('Reproduced'));
    expect(
      results.where((r) => r.startsWith('Not verified: the fix changed what reproduces the bug (calc_test.sh)')),
      hasLength(1),
    );
    expect(results.last, startsWith('Verified'));
  });

  test('the third identical call in a row is not run; the memory tool is offered', () async {
    File('$work/a.txt').writeAsStringSync('a');
    for (var i = 0; i < 3; i++) {
      gateway.reply(
        calls: [
          ('read', {'file_path': 'a.txt'}),
        ],
      );
    }
    gateway.reply(text: 'Done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-loop',
        initialMessage: 'read it',
        holdClientTools: true,
      ),
    );
    final events = await drive(session);
    final results = events.whereType<ToolResult>().map((r) => r.text).toList();
    expect(results, hasLength(3));
    expect(results.last, startsWith('Not run: this is the 3rd identical read call'));
    final tools = (gateway.requests.first['tools']! as List).map((t) => ((t as Map)['function'] as Map)['name']);
    expect(tools, contains('memory'));
    expect(tools, isNot(contains('bug_check')), reason: 'only Bug fix agents get it');
  });

  test('a Bug fix session from before workflows keeps bug_check and its repro', () async {
    File('$work/calc.sh').writeAsStringSync('echo 4\n');
    const repro = 'test "\$(sh calc.sh)" = 4';
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-old-bug',
        initialMessage: 'calc.sh prints 5 for 2 + 2',
        runInitial: false,
        holdClientTools: true,
      ),
    );
    final dir = '${tmp.path}/data/everyai-sessions/${session.id}';
    final specFile = File('$dir/spec.json');
    final old = jsonDecode(specFile.readAsStringSync()) as Map<String, Object?>;
    expect(old.containsKey('bug_check'), isFalse);
    specFile.writeAsStringSync(jsonEncode({...old, 'phase_flow': 'bugfix'}));
    File('$dir/phases.json')
        .writeAsStringSync(jsonEncode({'bugfix': true, 'phase': 'fix', 'repro_command': repro, 'reviews': 1}));
    await session.close();
    gateway
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(text: 'Fixed.');
    final reopened = await EveryAIHarness(
      dataDir: () async => '${tmp.path}/data',
      gatewayKey: () async => 'sk-test',
    ).attach(session.id);
    final driving = drive(reopened);
    await reopened.send('Check the fix');
    final events = await driving;
    final tools = (gateway.requests.first['tools']! as List).map((t) => ((t as Map)['function'] as Map)['name']);
    expect(tools, contains('bug_check'));
    expect(events.whereType<ToolResult>().single.text, startsWith('Verified'));
    expect(jsonDecode(File('$dir/bug_check.json').readAsStringSync()), containsPair('repro_command', repro));
  });

  group('per-call approvals', () {
    /// Runs [session] until it settles; at the first approval [decide] answers
    /// the waiting calls (action ids, in order).
    Future<List<HarnessEvent>> settle(
      HarnessSession session,
      Future<void> Function(List<ActionCall> calls) decide,
    ) async {
      final events = <HarnessEvent>[];
      final open = <ActionCall>[];
      final done = Completer<void>();
      var asked = false;
      final sub = session.events.listen((e) async {
        events.add(e);
        if (e is ActionCall) open.add(e);
        if (e is ToolResult) open.removeWhere((c) => c.id == e.actionId);
        if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation && !asked) {
          asked = true;
          await decide([...open]);
        }
        if (e is StateChange &&
            const {
              ExecutionStatus.finished,
              ExecutionStatus.error,
              ExecutionStatus.paused,
            }.contains(e.executionStatus)) {
          if (!done.isCompleted) done.complete();
        }
      });
      await done.future.timeout(const Duration(seconds: 20));
      await sub.cancel();
      return events;
    }

    test('allowing one call and refusing another runs the one and carries on', () async {
      gateway
        ..reply(
          calls: [
            ('write', {'file_path': 'a.txt', 'content': 'a\n'}),
            ('write', {'file_path': 'b.txt', 'content': 'b\n'}),
          ],
        )
        ..reply(text: 'Wrote a only.');
      final session = await harness.start(spec('write two files', mode: AgentMode.ask));
      expect(session, isA<PerCallApprovals>());
      final events = await settle(session, (calls) async {
        expect(calls, hasLength(2));
        await session.respond(accept: false, reason: 'Not b.', callIds: [calls[1].id]);
        await session.respond(accept: true, callIds: [calls[0].id]);
      });
      expect(File('$work/a.txt').existsSync(), isTrue);
      expect(File('$work/b.txt').existsSync(), isFalse);
      expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.finished);
      final rejected = events.whereType<ToolResult>().where((r) => r.outcome == ToolOutcome.rejected);
      expect(rejected, hasLength(1));
      final last = gateway.requests.last['messages']! as List<Object?>;
      final tools = last.where((m) => (m! as Map)['role'] == 'tool').map((m) => (m! as Map)['content']).toList();
      expect(tools, contains('Not b.'));
      expect(tools, hasLength(2));
    });

    test('Deny all parks the run', () async {
      gateway.reply(
        calls: [
          ('write', {'file_path': 'a.txt', 'content': 'a\n'}),
          ('bash', {'command': 'touch c.txt'}),
        ],
      );
      final session = await harness.start(spec('two things', mode: AgentMode.ask));
      final events = await settle(session, (_) => session.respond(accept: false, reason: 'No.'));
      expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.paused);
      expect(File('$work/a.txt').existsSync(), isFalse);
      expect(gateway.requests, hasLength(1), reason: 'no model call after Deny all');
    });

    test('read-only shell commands run beside other reads; changes and cd do not', () {
      LlmToolCall c(String name, Map<String, Object?> args) =>
          LlmToolCall(id: 'x', name: name, arguments: jsonEncode(args));
      expect(runsInParallel(c('read', {'file_path': 'a'})), isTrue);
      expect(runsInParallel(c('bash', {'command': 'git status && ls -la'})), isTrue);
      expect(runsInParallel(c('bash', {'command': 'rg foo lib | head'})), isTrue);
      expect(runsInParallel(c('bash', {'command': 'cd lib && ls'})), isFalse);
      expect(runsInParallel(c('bash', {'command': 'rm a.txt'})), isFalse);
      expect(runsInParallel(c('bash', {'command': 'ls', 'run_in_background': true})), isFalse);
      expect(runsInParallel(c('write', {'file_path': 'a', 'content': ''})), isFalse);
    });

    test('a batch of read-only commands runs together, results in order', () async {
      for (var i = 0; i < 3; i++) {
        File('$work/f$i.txt').writeAsStringSync('file $i\n');
      }
      gateway
        ..reply(
          calls: [
            for (var i = 0; i < 3; i++) ('bash', {'command': 'cat f$i.txt'}),
          ],
        )
        ..reply(text: 'Read them.');
      final session = await harness.start(spec('read the files'));
      final events = await drive(session);
      expect([for (final r in events.whereType<ToolResult>()) r.text.trim()], ['file 0', 'file 1', 'file 2']);
    });
  });
}
