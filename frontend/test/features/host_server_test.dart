import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/mcp_io.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_script.dart' show hostScriptsAvailable;
import 'package:every_ai/features/code/host/host_prompts.dart';
import 'package:every_ai/features/code/host/host_server_io.dart' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Timers the test fires by hand.
final class _FakeTimer implements Timer {
  _FakeTimer(this.after, this._fire);
  final Duration after;
  final void Function() _fire;
  var _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _fire();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// Answers memory at once; holds every other call until the test answers.
final class _FakeTools implements HostTools {
  final calls = <HostCall>[];
  final held = <String, Completer<HostResult>>{};
  final _ready = <HostCall>[];
  final _waiting = <Completer<HostCall>>[];

  /// The next held call, whether it came before or after this is asked.
  Future<HostCall> get arrived {
    if (_ready.isNotEmpty) return Future.value(_ready.removeAt(0));
    final w = Completer<HostCall>();
    _waiting.add(w);
    return w.future;
  }

  @override
  Future<HostResult> call(HostCall call) {
    calls.add(call);
    if (call.name == 'memory') return Future.value((text: 'saved: ${call.args['text']}', isError: false));
    if (call.name == 'fork') return Future.value((text: 'Started fork f1.', isError: false));
    if (call.name == 'screenshot') {
      call.images.add((mime: 'image/png', data: 'iVBORw0KGgo='));
      return Future.value((text: 'Screenshot of Counter: /p/shot.png.', isError: false));
    }
    final c = held[call.id] = Completer();
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(call);
    } else {
      _ready.add(call);
    }
    return c.future;
  }
}

/// [_FakeTools] that also lists two workflows as prompts.
final class _PromptTools extends _FakeTools implements HostPrompts {
  @override
  Future<List<WorkflowPrompt>> workflowPrompts() async => const [
    (id: 'ultra', title: 'Ultra', description: 'Many changes at once', whenToUse: 'big tasks', args: '{items}'),
    (id: 'mine', title: 'Mine', description: '', whenToUse: '', args: ''),
  ];
}

void main() {
  late DateTime clock;
  late List<_FakeTimer> timers;
  late HostServer server;
  late _FakeTools tools;
  late HostToken tok;
  void Function()? onNow;
  const held = Duration(seconds: 300);

  setUp(() async {
    clock = DateTime(2026, 11, 4);
    timers = [];
    onNow = null;
    server = createHostServer(
      idleLimit: const Duration(hours: 1),
      heldLimit: held,
      now: () {
        onNow?.call();
        return clock;
      },
      timer: (after, fire) {
        final t = _FakeTimer(after, fire);
        timers.add(t);
        return t;
      },
    );
    tools = _FakeTools();
    tok = await server.mint('s1', tools);
  });

  tearDown(() => server.stop());

  Future<http.Response> post(Object? body, {String? token, Map<String, String> headers = const {}}) => http.post(
    tok.url,
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      'Authorization': 'Bearer ${token ?? tok.token}',
      ...headers,
    },
    body: jsonEncode(body),
  );

  Map<String, Object?> rpc(String method, [Map<String, Object?> params = const {}, Object id = 1]) => {
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': params,
  };

  /// The JSON-RPC reply in an SSE body.
  Map<String, Object?> sseReply(String body) =>
      jsonDecode(const LineSplitter().convert(body).lastWhere((l) => l.startsWith('data:')).substring(5))
          as Map<String, Object?>;

  Map<String, Object?> resultOf(http.Response r) =>
      (r.headers['content-type']!.contains('event-stream') ? sseReply(r.body) : jsonDecode(r.body) as Map)['result']
          as Map<String, Object?>;

  Object? errorCode(http.Response r) => ((jsonDecode(r.body) as Map)['error'] as Map)['code'];

  _FakeTimer heldTimer() => timers.firstWhere((t) => t.after == held);

  test('our own MCP client lists the tools in a fixed order and calls one', () async {
    final c = await McpConnection.open('everyai', {
      'url': '${tok.url}',
      'headers': {'Authorization': 'Bearer ${tok.token}'},
    });
    addTearDown(c.close);
    expect(
      [for (final t in c.tools) t['name']],
      [
        'ask_user_question',
        'present_plan',
        'memory',
        'saved_plans',
        'fork',
        'check_forks',
        'answer_fork',
        'stop_fork',
        'bug_check',
        'check',
        'diff_stats',
        'goal_check',
        if (hostScriptsAvailable) 'run_script',
        'run_workflow',
        'report_issue',
        'browser',
        'screenshot',
        'app_run',
      ],
    );
    expect(c.tools.first['description'], contains('come back as the result of this call'));
    expect(c.tools.first['inputSchema'], isA<Map<String, Object?>>());
    final out = await c.call('memory', {'action': 'add', 'text': '- run make'});
    expect(out.text, 'saved: - run make');
    expect(out.isError, isFalse);
    expect(tools.calls.single.sessionId, 's1');
  });

  test('a result with pictures sends them after its text; a text-only one is unchanged', () async {
    final shot = resultOf(await post(rpc('tools/call', {'name': 'screenshot', 'arguments': <String, Object?>{}})));
    expect(shot['content'], [
      {'type': 'text', 'text': 'Screenshot of Counter: /p/shot.png.'},
      {'type': 'image', 'data': 'iVBORw0KGgo=', 'mimeType': 'image/png'},
    ]);
    expect(shot['isError'], isFalse);
    final memory = resultOf(
      await post(
        rpc('tools/call', {
          'name': 'memory',
          'arguments': {'text': 'x'},
        }),
      ),
    );
    expect(memory['content'], [
      {'type': 'text', 'text': 'saved: x'},
    ]);
  });

  test('a fork call reaches the session and returns at once, with no held timer', () async {
    final c = await McpConnection.open('everyai', {
      'url': '${tok.url}',
      'headers': {'Authorization': 'Bearer ${tok.token}'},
    });
    addTearDown(c.close);
    final fork = c.tools.firstWhere((t) => t['name'] == 'fork');
    expect((fork['inputSchema']! as Map)['required'], ['task']);
    final out = await c.call('fork', {'task': 'Add the settings page', 'worktree': true});
    expect(out.text, 'Started fork f1.');
    expect(tools.calls.single.args, {'task': 'Add the settings page', 'worktree': true});
    expect(timers.where((t) => t.after == held), isEmpty);
  });

  test('the checks: bug_check and check run commands, the rest only read', () async {
    final c = await McpConnection.open('everyai', {
      'url': '${tok.url}',
      'headers': {'Authorization': 'Bearer ${tok.token}'},
    });
    addTearDown(c.close);
    Map<String, Object?> hints(String name) =>
        c.tools.firstWhere((t) => t['name'] == name)['annotations']! as Map<String, Object?>;
    for (final name in ['bug_check', 'check']) {
      expect(hints(name), {'readOnlyHint': false, 'destructiveHint': true}, reason: name);
    }
    for (final name in ['diff_stats', 'goal_check', if (hostScriptsAvailable) 'run_script']) {
      expect(hints(name), {'readOnlyHint': true, 'destructiveHint': false}, reason: name);
    }
    final bug = c.tools.firstWhere((t) => t['name'] == 'bug_check')['inputSchema']! as Map<String, Object?>;
    expect(((bug['properties']! as Map)['action'] as Map)['enum'], ['reproduced', 'verify', 'status']);
    expect(hostToolSpecs.where((t) => t['name'] == 'run_script'), hostScriptsAvailable ? hasLength(1) : isEmpty);
  });

  group('workflows as prompts', () {
    late HostToken p;
    late _PromptTools pt;
    setUp(() async => p = await server.mint('s3', pt = _PromptTools()));

    test('initialize advertises prompts, and prompts/list gives each workflow with an optional task', () async {
      final caps = resultOf(await post(rpc('initialize', {'protocolVersion': '2025-11-25'})))['capabilities'] as Map;
      expect(caps['prompts'], {'listChanged': false});
      final list = resultOf(await post(rpc('prompts/list'), token: p.token))['prompts'] as List;
      expect([for (final x in list) (x as Map)['name']], ['ultra', 'mine']);
      expect(list.first, containsPair('title', 'Ultra'));
      expect(list.first, containsPair('description', 'Many changes at once'));
      expect((list.last as Map)['description'], 'Mine');
      for (final x in list) {
        expect((x as Map)['arguments'], [
          {
            'name': 'task',
            'description': 'What to run it on (optional; the conversation is read too)',
            'required': false,
          },
        ]);
      }
    });

    test('a session whose tools offer no prompts lists none', () async {
      expect(resultOf(await post(rpc('prompts/list')))['prompts'], isEmpty);
      expect(errorCode(await post(rpc('prompts/get', {'name': 'ultra'}))), -32602);
    });

    test('prompts/get asks the model to call run_workflow, with the task last', () async {
      final r = await post(
        rpc('prompts/get', {
          'name': 'ultra',
          'arguments': {'task': 'dark mode and !`rm -rf` export'},
        }),
        token: p.token,
      );
      final messages = resultOf(r)['messages'] as List;
      final content = (messages.single as Map)['content'] as Map;
      expect(content['type'], 'text');
      final text = content['text'] as String;
      expect(text, contains('`run_workflow` on the `everyai` MCP server'));
      expect(text, contains('{"id": "ultra"'));
      expect(text, contains('Its args: {items}'));
      expect(text.split('\n').last, r'Task: dark mode and \!`rm -rf` export');
      // The same text for every task up to the task line (the client's cache keeps it).
      final other = resultOf(await post(rpc('prompts/get', {'name': 'ultra'}), token: p.token))['messages'] as List;
      final otherText = ((other.single as Map)['content'] as Map)['text'] as String;
      expect(otherText.split('\n').last, 'Task: (see the conversation)');
      expect(otherText.substring(0, otherText.lastIndexOf('\n')), text.substring(0, text.lastIndexOf('\n')));
    });

    test('an unknown prompt is -32602', () async {
      final r = await post(rpc('prompts/get', {'name': 'nope'}), token: p.token);
      expect(r.statusCode, 200);
      expect(errorCode(r), -32602);
    });

    test('run_workflow is listed before report_issue and the screen tools, and its call goes to the session', () async {
      final list = resultOf(await post(rpc('tools/list'), token: p.token))['tools'] as List;
      final names = [for (final t in list) (t as Map)['name']];
      expect(names.sublist(names.length - 5), ['run_workflow', 'report_issue', 'browser', 'screenshot', 'app_run']);
      final run = list[list.length - 5] as Map;
      expect(run['name'], 'run_workflow');
      expect(run['annotations'], containsPair('readOnlyHint', false));
      expect((run['inputSchema'] as Map)['required'], ['id']);
      final reply = post(
        rpc('tools/call', {
          'name': 'run_workflow',
          'arguments': {'id': 'ultra', 'args': <String, Object?>{}},
        }),
        token: p.token,
      );
      final call = await pt.arrived;
      expect(call.name, 'run_workflow');
      expect(call.args['id'], 'ultra');
      pt.held[call.id]!.complete((text: 'Started Ultra (run r1).', isError: false));
      expect(((resultOf(await reply)['content'] as List).single as Map)['text'], 'Started Ultra (run r1).');
    });
  });

  test('params, method or arguments of the wrong type get a JSON-RPC error', () async {
    var r = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list', 'params': <Object?>[]});
    expect(r.statusCode, 400);
    expect(errorCode(r), -32600);
    r = await post({'jsonrpc': '2.0', 'id': 1, 'method': 3});
    expect(r.statusCode, 400);
    r = await post(rpc('tools/call', {'name': 'memory', 'arguments': <Object?>[]}));
    expect(r.statusCode, 200);
    expect(errorCode(r), -32602);
    expect(tools.calls, isEmpty);
  });

  test('initialize negotiates the version and never starts a session', () async {
    var r = await post(rpc('initialize', {'protocolVersion': '2025-06-18'}));
    expect(resultOf(r)['protocolVersion'], '2025-06-18');
    expect(r.headers['mcp-session-id'], isNull);
    r = await post(rpc('initialize', {'protocolVersion': '2024-01-01'}));
    expect(resultOf(r)['protocolVersion'], '2025-11-25');
    expect(r.headers['mcp-session-id'], isNull);
  });

  test('notifications, ping, other verbs, batches and unknown methods', () async {
    expect((await post({'jsonrpc': '2.0', 'method': 'notifications/initialized'})).statusCode, 202);
    expect(resultOf(await post(rpc('ping'))), isEmpty);
    final auth = {'Authorization': 'Bearer ${tok.token}'};
    expect((await http.get(tok.url, headers: auth)).statusCode, 405);
    expect((await http.delete(tok.url, headers: auth)).statusCode, 405);
    expect((await post([rpc('ping')])).statusCode, 400);
    final r = await post(rpc('resources/list'));
    expect(r.statusCode, 200);
    expect(errorCode(r), -32601);
  });

  test('a missing, wrong, revoked or expired token is a 401', () async {
    Future<void> rejected(http.Response r) async {
      expect(r.statusCode, 401);
      expect(r.headers['www-authenticate'], startsWith('Bearer'));
    }

    await rejected(await http.post(tok.url, body: jsonEncode(rpc('ping'))));
    await rejected(await post(rpc('ping'), token: '${tok.token}x'));

    final other = await server.mint('s2', tools);
    await server.revoke(other.token);
    await rejected(await post(rpc('ping'), token: other.token));

    // touch keeps a token alive across the idle limit; without it, it expires.
    clock = clock.add(const Duration(minutes: 50));
    server.touch(tok.token);
    clock = clock.add(const Duration(minutes: 50));
    expect((await post(rpc('ping'))).statusCode, 200);
    clock = clock.add(const Duration(minutes: 61));
    await rejected(await post(rpc('ping')));
  });

  test('touch says when the token already expired', () async {
    clock = clock.add(const Duration(minutes: 61));
    expect(server.touch(tok.token), isFalse);
  });

  test('the server closes when the last token expires without any request', () async {
    final port = tok.url.port;
    clock = clock.add(const Duration(hours: 1));
    timers.lastWhere((t) => t.isActive && t.after == const Duration(hours: 1)).fire();
    await server.revoke('none'); // waits for the close queued before it
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
  });

  test('a failed bind fails only its own mint', () async {
    var fail = true;
    final s = io.createHostServer(
      idleLimit: const Duration(hours: 1),
      heldLimit: held,
      keepAlive: const Duration(seconds: 15),
      bind: () {
        if (fail) {
          fail = false;
          throw const SocketException('no free port');
        }
        return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      },
    );
    addTearDown(s.stop);
    await expectLater(s.mint('a', tools), throwsA(isA<SocketException>()));
    final t = await s.mint('b', tools);
    final r = await http.post(
      t.url,
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${t.token}'},
      body: jsonEncode(rpc('ping')),
    );
    expect(r.statusCode, 200);
    // The failed mint left no token behind, so the last revoke closes the server.
    await s.revoke(t.token);
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, t.url.port), throwsA(isA<SocketException>()));
  });

  test('a foreign Host or Origin is a 403 (DNS rebinding)', () async {
    expect((await post(rpc('ping'), headers: {'Origin': 'http://evil.example'})).statusCode, 403);
    expect((await post(rpc('ping'), headers: {'Origin': 'http://localhost:${tok.url.port}'})).statusCode, 200);
    final c = HttpClient();
    addTearDown(c.close);
    final req = await c.postUrl(tok.url);
    req.headers
      ..host = 'evil.example'
      ..set('authorization', 'Bearer ${tok.token}');
    req.write(jsonEncode(rpc('ping')));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 403);
  });

  test('an unknown legacy version header is a 400', () async {
    expect((await post(rpc('ping'), headers: {'MCP-Protocol-Version': '1999-01-01'})).statusCode, 400);
    expect((await post(rpc('ping'), headers: {'MCP-Protocol-Version': '2025-06-18'})).statusCode, 200);
  });

  group('2026-07-28 requests (from the spec text)', () {
    Map<String, Object?> meta([String v = '2026-07-28']) => {
      '_meta': {'io.modelcontextprotocol/protocolVersion': v},
    };
    Map<String, String> heads(String method) => {'MCP-Protocol-Version': '2026-07-28', 'Mcp-Method': method};

    test('server/discover and tools/list', () async {
      var r = await post(rpc('server/discover', meta()), headers: heads('server/discover'));
      expect(resultOf(r)['supportedVersions'], contains('2026-07-28'));
      expect(resultOf(r)['resultType'], 'complete');
      r = await post(rpc('tools/list', meta()), headers: heads('tools/list'));
      final list = resultOf(r);
      expect(list['resultType'], 'complete');
      expect(list['ttlMs'], isA<int>());
      expect((list['tools'] as List).length, hostToolSpecs.length);
    });

    test('a tools/call names the tool in Mcp-Name, base64 too', () async {
      final params = {
        ...meta(),
        'name': 'memory',
        'arguments': {'text': 'x'},
      };
      final name = '=?base64?${base64.encode(utf8.encode('memory'))}?=';
      final r = await post(rpc('tools/call', params), headers: {...heads('tools/call'), 'Mcp-Name': name});
      expect(resultOf(r)['resultType'], 'complete');
      expect(((resultOf(r)['content'] as List).single as Map)['text'], 'saved: x');
    });

    test('a prompts/get names the prompt in Mcp-Name', () async {
      final p = await server.mint('s3', _PromptTools());
      Future<http.Response> get(String? name) => post(
        rpc('prompts/get', {...meta(), 'name': 'ultra'}),
        token: p.token,
        headers: {...heads('prompts/get'), 'Mcp-Name': ?name},
      );
      expect(((resultOf(await get('ultra'))['messages'] as List).single as Map)['role'], 'user');
      for (final name in ['mine', null]) {
        final r = await get(name);
        expect(r.statusCode, 400);
        expect(errorCode(r), -32020);
      }
    });

    test('mismatched headers and unknown versions are 400s', () async {
      var r = await post(rpc('tools/list', meta()), headers: heads('ping'));
      expect(r.statusCode, 400);
      expect(errorCode(r), -32020);
      r = await post(rpc('tools/list', meta('2027-01-01')), headers: heads('tools/list'));
      expect(r.statusCode, 400);
      expect(errorCode(r), -32022);
      expect(((jsonDecode(r.body) as Map)['error'] as Map)['data'], containsPair('supported', contains('2026-07-28')));
      r = await post(rpc('resources/list', meta()), headers: heads('resources/list'));
      expect(r.statusCode, 404);
      expect(errorCode(r), -32601);
    });
  });

  Future<http.Response> ask() => post(
    rpc('tools/call', {
      'name': 'ask_user_question',
      'arguments': {'questions': <Object?>[]},
    }, 7),
  );

  test('a held call waits for the answer', () async {
    final reply = ask();
    final call = await tools.arrived;
    expect(call.name, 'ask_user_question');
    tools.held[call.id]!.complete((text: 'Postgres', isError: false));
    final result = resultOf(await reply);
    expect(((result['content'] as List).single as Map)['text'], 'Postgres');
    expect(result['isError'], isFalse);
  });

  test('a waiting call sends keep-alives, as progress when asked for', () async {
    final reply = post(
      rpc('tools/call', {
        'name': 'present_plan',
        'arguments': <String, Object?>{},
        '_meta': {'progressToken': 'p1'},
      }),
    );
    final call = await tools.arrived;
    timers.firstWhere((t) => t.after == const Duration(seconds: 15)).fire();
    tools.held[call.id]!.complete((text: 'approved', isError: false));
    final body = (await reply).body;
    expect(body, contains('"method":"notifications/progress"'));
    expect(body, contains('"progressToken":"p1"'));
    expect(sseReply(body)['id'], 1);
  });

  test('a held call times out with an error result', () async {
    final reply = ask();
    final call = await tools.arrived;
    heldTimer().fire();
    final result = resultOf(await reply);
    expect(((result['content'] as List).single as Map)['text'], startsWith('Error (timeout)'));
    expect(result['isError'], isTrue);
    expect(await call.ended, HostEnd.timedOut);
    tools.held[call.id]!.complete((text: 'late', isError: false)); // ignored
  });

  test('a plan that timed out is not approved', () async {
    final reply = post(rpc('tools/call', {'name': 'present_plan', 'arguments': <String, Object?>{}}));
    await tools.arrived;
    heldTimer().fire();
    final text = ((resultOf(await reply)['content'] as List).single as Map)['text'] as String;
    expect(text, contains('NOT approved'));
    expect(text, contains('do not start building'));
    expect(text, isNot(contains('Carry on')));
  });

  test('closing the session ends its pending calls and its token', () async {
    final reply = ask();
    final call = await tools.arrived;
    await server.revokeSession('s1');
    final result = resultOf(await reply);
    expect(((result['content'] as List).single as Map)['text'], 'Error: the EveryAI session ended.');
    expect(await call.ended, HostEnd.sessionClosed);
  });

  test('a token revoked while its call body is read runs nothing', () async {
    await server.mint('s2', tools); // keeps the server up
    final c = HttpClient();
    addTearDown(() => c.close(force: true));
    final body = utf8.encode(
      jsonEncode(
        rpc('tools/call', {
          'name': 'memory',
          'arguments': {'action': 'add', 'text': 'x'},
        }),
      ),
    );
    final req = await c.postUrl(tok.url);
    req.headers
      ..contentType = ContentType.json
      ..set('authorization', 'Bearer ${tok.token}');
    req.contentLength = body.length;
    final authed = Completer<void>();
    onNow = () {
      if (!authed.isCompleted) authed.complete();
    };
    req.add(body.sublist(0, 10));
    await req.flush();
    await authed.future; // the server checked the token and now reads the body
    onNow = null;
    await server.revokeSession('s1');
    req.add(body.sublist(10));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 401);
    expect(tools.calls, isEmpty);
  });

  test('a revoked session token is refused while the server stays up', () async {
    final keep = await server.mint('s2', tools);
    await server.revokeSession('s1');
    expect((await post(rpc('ping'))).statusCode, 401);
    expect((await post(rpc('ping'), token: keep.token)).statusCode, 200);
  });

  test('a client that leaves cancels its call', () async {
    final c = HttpClient();
    final req = await c.postUrl(tok.url);
    req.headers
      ..contentType = ContentType.json
      ..set('authorization', 'Bearer ${tok.token}');
    req.write(jsonEncode(rpc('tools/call', {'name': 'present_plan', 'arguments': <String, Object?>{}})));
    final res = await req.close();
    expect(res.headers.contentType?.mimeType, 'text/event-stream');
    final sub = res.listen((_) {});
    final call = await tools.arrived;
    await sub.cancel();
    c.close(force: true);
    expect(await call.ended, HostEnd.clientGone);
  });

  test('notifications/cancelled ends the call it names', () async {
    final reply = ask();
    final call = await tools.arrived;
    final r = await post({
      'jsonrpc': '2.0',
      'method': 'notifications/cancelled',
      'params': {'requestId': 7},
    });
    expect(r.statusCode, 202);
    expect(await call.ended, HostEnd.cancelled);
    expect(resultOf(await reply)['isError'], isTrue);
  });

  test('the server stops with the last token and starts again on the next', () async {
    final port = tok.url.port;
    await server.revoke(tok.token);
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
    tok = await server.mint('s2', tools);
    expect((await post(rpc('ping'))).statusCode, 200);
  });
}
