import 'dart:async';

import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

const _handshake = '''
{"dir":"out","msg":{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":1,"cwd":"{{cwd}}"}}}
{"dir":"in","msg":{"jsonrpc":"2.0","id":7,"result":{"agent":"fake","cwd":"{{cwd}}"}}}
{"dir":"in","msg":{"jsonrpc":"2.0","method":"session/update","params":{"text":"hello"}}}
{"dir":"in","msg":{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"tool":"Bash"}}}
{"dir":"out","msg":{"jsonrpc":"2.0","id":"perm-1","result":{"outcome":"allow"}}}
{"dir":"out","msg":{"method":"session/cancel","jsonrpc":"2.0"}}
''';

void main() {
  test('requests, notifications and requests from the agent play through the peer', () async {
    final channel = ReplayChannel(_handshake);
    final notes = <(String, Object?)>[];
    final asked = <String>[];
    final peer = JsonRpcPeer(
      channel,
      onNotify: (m, p) => notes.add((m, p)),
      onRequest: (m, p) async {
        asked.add(m);
        return {'outcome': 'allow'};
      },
    );
    // Our id is 1, the recording's 7: the reply comes back with ours.
    final result = await peer.request('initialize', {'protocolVersion': 1, 'cwd': '/work/tree'});
    expect(result, {'agent': 'fake', 'cwd': '/work/tree'});
    expect(channel.sent.first['id'], 1);
    await _until(() => asked.isNotEmpty && notes.isNotEmpty);
    expect(notes.single.$1, 'session/update');
    expect(notes.single.$2, {'text': 'hello'});
    expect(asked, ['session/request_permission']);
    await _until(() => channel.sent.length == 2);
    peer.notify('session/cancel');
    await channel.finished;
    channel.expectFinished();
  });

  test('a request from the agent without a handler is refused as not found', () async {
    final channel = ReplayChannel('''
{"dir":"in","msg":{"jsonrpc":"2.0","id":3,"method":"fs/read_text_file","params":{}}}
{"dir":"out","msg":{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Not supported by this client"}}}
''');
    JsonRpcPeer(channel);
    await channel.finished;
    channel.expectFinished();
  });

  test('a handler error goes back as an error reply', () async {
    final channel = ReplayChannel('''
{"dir":"in","msg":{"id":1,"method":"ask"}}
{"dir":"out","msg":{"id":1,"error":{"code":-32602,"message":"bad"}}}
''');
    JsonRpcPeer(channel, writeVersion: false, onRequest: (m, p) async => throw const JsonRpcError(-32602, 'bad'));
    await channel.finished;
    channel.expectFinished();
  });

  test('error replies throw, and pending requests fail when the agent goes away', () async {
    final channel = ReplayChannel('''
{"dir":"out","msg":{"jsonrpc":"2.0","id":1,"method":"a"}}
{"dir":"in","msg":{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nope"}}}
{"dir":"out","msg":{"jsonrpc":"2.0","id":2,"method":"b"}}
{"dir":"eof"}
''');
    final peer = JsonRpcPeer(channel);
    await expectLater(peer.request('a'), throwsA(isA<JsonRpcError>().having((e) => e.message, 'message', 'nope')));
    await expectLater(
      peer.request('b'),
      throwsA(isA<JsonRpcError>().having((e) => e.code, 'code', JsonRpcError.closedCode)),
    );
    await peer.done;
    await expectLater(peer.request('c'), throwsA(isA<JsonRpcError>()));
  });

  test('lines that are not JSON objects are skipped', () async {
    final channel = ReplayChannel('''
{"dir":"out","msg":{"jsonrpc":"2.0","id":1,"method":"a"}}
{"dir":"in","raw":"Starting the agent..."}
{"dir":"in","raw":"{not json"}
{"dir":"in","msg":{"jsonrpc":"2.0","id":1,"result":"ok"}}
''');
    final peer = JsonRpcPeer(channel);
    expect(await peer.request('a'), 'ok');
  });

  test('a message that differs fails with its line and path', () {
    final channel = ReplayChannel('''
// a comment line
{"dir":"out","msg":{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"cwd":"/a"}}}
''');
    expect(
      () => channel.send('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"cwd":"/b"}}'),
      throwsA(isA<TestFailure>().having((f) => f.message, 'message', contains(r'line 2: differs at $.params.cwd'))),
    );
    expect(channel.expectFinished, throwsA(isA<TestFailure>()));
  });

  test('a script with lines left unsent is not finished', () {
    final channel = ReplayChannel('{"dir":"out","msg":{"method":"x"}}');
    expect(
      channel.expectFinished,
      throwsA(isA<TestFailure>().having((f) => f.message, 'message', contains('line 1: still waiting'))),
    );
  });
}

Future<void> _until(bool Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
