import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/remote/data/host_bridge.dart';
import 'package:every_ai/features/remote/data/host_link.dart';
import 'package:every_ai/features/remote/data/relay_client.dart';
import 'package:every_ai/features/remote/domain/remote_crypto.dart';
import 'package:every_ai/features/remote/domain/remote_protocol.dart';
import 'package:every_ai/features/remote/host_mirror.dart';
import 'package:every_ai/features/remote/remote_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket/testing.dart';
import 'package:web_socket/web_socket.dart';

/// The backend relay in memory, as remote.zig behaves: host frames carry a
/// 4-byte channel, client frames are bare, text frames are notices. Every
/// binary frame is recorded so the test can check nothing readable crosses.
/// The backend relay in memory, as remote.zig behaves: host frames carry a
/// 4-byte channel, client frames are bare, text frames are notices. Every
/// binary frame is recorded so the test can check nothing readable crosses.
/// Sends to a socket the other end may have closed already (test teardown).
void _quietly(void Function() send) {
  try {
    send();
  } on WebSocketConnectionClosed {
    // Gone.
  }
}

final class _FakeRelay {
  WebSocket? _host;
  final _clients = <int, (WebSocket, Map<String, Object?>)>{};
  int _next = 7;
  final relayed = <Uint8List>[];

  /// Frames over the backend's 4 MiB cap (it would drop the socket).
  final oversized = <int>[];

  /// Client frames to lose on the way (an init that reached a host not ready yet).
  int dropClientFrames = 0;

  void _record(Uint8List data, {int prefix = 0}) {
    relayed.add(data);
    if (data.length - prefix > 4 << 20) oversized.add(data.length);
  }

  /// Tells every client again that the host is online (a quick host reconnect).
  void announceHost() {
    for (final c in _clients.values) {
      _quietly(() => c.$1.sendText('{"type":"host_online"}'));
    }
  }

  Future<WebSocket> connectHost(Uri url, String token) async {
    expect(token, 'rh_token');
    final (mine, theirs) = fakes();
    _host = mine;
    mine.events.listen((e) {
      switch (e) {
        case BinaryDataReceived(:final data):
          _record(data, prefix: 4);
          final channel = ByteData.sublistView(data, 0, 4).getUint32(0);
          _quietly(() => _clients[channel]?.$1.sendBytes(Uint8List.sublistView(data, 4)));
        case TextDataReceived(:final text):
          final c = jsonDecode(text) as Map<String, Object?>;
          if (c['type'] == 'close_channel') _clients.remove(c['channel'])?.$1.sendText('{"type":"closed"}');
        case CloseReceived():
          if (_host == mine) _hostGone();
      }
    });
    mine.sendText(
      jsonEncode({
        'type': 'hello',
        'host_id': 'host-1',
        'clients': [for (final e in _clients.entries) e.value.$2],
        'pending_pairings': const <Object?>[],
      }),
    );
    for (final c in _clients.values) {
      _quietly(() => c.$1.sendText('{"type":"host_online"}'));
    }
    return theirs;
  }

  RelayConnector connectClient({required String deviceId, required String publicKey}) => (url, token) async {
    expect(url.path, '/v1/remote/client/host-1');
    final (mine, theirs) = fakes();
    final channel = _next++;
    final info = {'channel': channel, 'device_id': deviceId, 'device_name': 'Phone', 'public_key': publicKey};
    _clients[channel] = (mine, info);
    mine.events.listen((e) {
      if (e case BinaryDataReceived(:final data)) {
        _record(data);
        if (dropClientFrames > 0) {
          dropClientFrames--;
          return;
        }
        final frame = Uint8List(4 + data.length);
        ByteData.sublistView(frame, 0, 4).setUint32(0, channel);
        frame.setRange(4, frame.length, data);
        _quietly(() => _host?.sendBytes(frame));
      }
    });
    mine.sendText(jsonEncode({'type': 'hello', 'channel': channel, 'host_online': _host != null}));
    _host?.sendText(jsonEncode({'type': 'client_open', ...info}));
    return theirs;
  };

  void _hostGone() {
    _host = null;
    for (final c in _clients.values) {
      _quietly(() => c.$1.sendText('{"type":"host_offline"}'));
    }
  }

  /// The host drops off the relay (quit, sleep, network).
  Future<void> dropHost() async {
    await _host?.close();
    _hostGone();
  }
}

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<T> _until<T>(T Function() read, bool Function(T) cond) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Map<String, Object?> _agent(String text, {bool stream = false}) => {
  'kind': 'MessageEvent',
  'source': 'agent',
  if (stream) 'stream': true,
  'llm_message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

const _command = {
  'kind': 'ActionEvent',
  'tool_name': 'terminal',
  'tool_call_id': 'call-1',
  'action': {'kind': 'TerminalAction', 'command': 'touch notes.txt'},
};

const _output = {
  'kind': 'ObservationEvent',
  'observation': {
    'kind': 'TerminalObservation',
    'content': [
      {'type': 'text', 'text': ''},
    ],
    'exit_code': 0,
  },
};

/// What a device shows of one session: [MirrorFold] over what the host sent it.
final class _Device {
  _Device(this.session);
  final String session;
  final fold = MirrorFold();
  var state = const RemoteSessionState();
  final lists = <Map<String, Object?>>[];
  final done = <int, String?>{};

  void receive(Map<String, Object?> m) {
    switch (m['t']) {
      case Tunnel.sessions:
        lists.add(m);
      case Tunnel.done:
        done[m['id']! as int] = m['error'] as String?;
      default:
        if (m['s'] == session) state = fold.apply(state, m);
    }
  }

  List<String> get said => [
    for (final item in state.session.transcript.items)
      if (item is UserTurn) 'user:${item.text}' else if (item is AgentText) 'agent:${item.text}',
  ];
}

void main() {
  group('tunnel', () {
    late _FakeRelay relay;
    late RemoteIdentity hostKey;
    late RemoteIdentity deviceKey;
    late RemoteHostLink hostLink;
    late RemoteClient client;
    var approved = <String, String>{};

    /// The host answers every `act` and pushes what the test asks for.
    late HostBridge bridge;
    final hostGot = <Map<String, Object?>>[];

    Future<void> startHost() async {
      hostLink = RemoteHostLink(
        url: Uri.parse('ws://backend/v1/remote/host'),
        token: 'rh_token',
        connect: relay.connectHost,
        approvedKey: (id) => approved[id],
        bridge: (send) => bridge = HostBridge(
          identity: hostKey,
          hostId: 'host-1',
          send: send,
          onMessage: (channel, m) {
            hostGot.add(m);
            if (m['t'] == Tunnel.act) {
              bridge.send(channel, {'t': Tunnel.done, 'id': m['id'], if (m['kind'] == 'refuse') 'error': 'No.'});
            } else if (m['t'] == Tunnel.list) {
              bridge.send(channel, {'t': Tunnel.sessions, 'host': 'Mac', 'big': m['big']});
            }
          },
        ),
      )..start();
    }

    setUp(() async {
      relay = _FakeRelay();
      hostGot.clear();
      hostKey = await RemoteIdentity.generate();
      deviceKey = await RemoteIdentity.generate();
      approved = {'dev-1': deviceKey.publicKeyBase64};
      await startHost();
      client = RemoteClient(
        hostId: 'host-1',
        hostPublicKey: hostKey.publicKey,
        identity: deviceKey,
        deviceToken: 'rd_token',
        relayUrl: Uri.parse('ws://backend/v1/remote/client/host-1'),
        connect: relay.connectClient(deviceId: 'dev-1', publicKey: deviceKey.publicKeyBase64),
        readyTimeout: const Duration(seconds: 3),
        handshakeRetry: const Duration(milliseconds: 100),
      );
    });

    tearDown(() async {
      await client.close();
      await hostLink.close();
    });

    test('actions are answered, refusals carry the reason, and pushes arrive', () async {
      await client.call({'t': Tunnel.act, 's': 's1', 'kind': MirrorAction.stop});
      await expectLater(
        client.call({'t': Tunnel.act, 's': 's1', 'kind': 'refuse'}),
        throwsA(isA<RemoteRefused>().having((e) => e.message, 'message', 'No.')),
      );
      final pushed = client.messages.first;
      await client.send({'t': Tunnel.list});
      expect((await pushed.timeout(const Duration(seconds: 3)))['host'], 'Mac');
      expect(hostGot.map((m) => m['t']), [Tunnel.act, Tunnel.act, Tunnel.list]);
    });

    test('nothing readable crosses the relay', () async {
      await client.call({
        't': Tunnel.act,
        's': 'secret-session',
        'kind': MirrorAction.send,
        'args': {'text': 'hush'},
      });
      final joined = latin1.decode([for (final f in relay.relayed) ...f]);
      for (final secret in ['secret-session', 'hush', MirrorAction.send, Tunnel.act]) {
        expect(joined, isNot(contains(secret)));
      }
    });

    test("messages past the relay's frame cap go across in parts", () async {
      final pushed = client.messages.first;
      await client.send({'t': Tunnel.list, 'big': 'x' * (6 << 20)});
      expect((await pushed.timeout(const Duration(seconds: 5)))['big'], hasLength(6 << 20));
      expect(relay.oversized, isEmpty);
    });

    test('a device the host did not approve gets nothing through', () async {
      approved = {};
      await hostLink.close();
      await startHost();
      await expectLater(client.call({'t': Tunnel.act, 'kind': 'x'}), throwsA(isA<RemoteUnavailable>()));
      expect(hostGot, isEmpty);
    });

    test('a host with other keys is refused before anything is sent', () async {
      await hostLink.close();
      hostKey = await RemoteIdentity.generate();
      await startHost();
      await expectLater(client.call({'t': Tunnel.act, 'kind': 'x'}), throwsA(isA<RemoteUnavailable>()));
      expect(client.status, RemoteLinkStatus.keyMismatch);
      expect(hostGot, isEmpty);
    });

    test('the link comes back when the host does, and fails while it stays away', () async {
      await client.call({'t': Tunnel.act, 'kind': 'x'});
      await relay.dropHost();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.status, RemoteLinkStatus.hostOffline);
      // The host link reconnects by itself; an action made meanwhile waits for it.
      await client.call({'t': Tunnel.act, 'kind': 'x'});
      expect(client.status, RemoteLinkStatus.ready);

      await hostLink.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await expectLater(client.call({'t': Tunnel.act, 'kind': 'x'}), throwsA(isA<RemoteUnavailable>()));
    });

    test('a lost handshake is sent again', () async {
      relay.dropClientFrames = 1;
      await client.call({'t': Tunnel.act, 'kind': 'x'});
      expect(client.status, RemoteLinkStatus.ready);
    });
  });

  group('mirror', () {
    late AppDatabase db;
    late ProviderContainer container;
    late HostMirror mirror;
    late Map<int, _Device> devices;
    late CodeSessionInfo info;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([
        const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
      ]);
      final harness = FakeHarness(
        step: Duration.zero,
        turns: [
          [_command, _output, _agent('made the file', stream: true)],
          [_agent('read your notes')],
        ],
      );
      final mirrorProvider = Provider<HostMirror>((ref) => HostMirror(ref, hostName: 'Mac'));
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          harnessProvider.overrideWithValue(harness),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
        ],
      );
      devices = {1: _Device(''), 2: _Device('')};
      mirror = container.read(mirrorProvider)
        ..send = (channel, m) {
          // Through JSON, as the tunnel carries it.
          devices[channel]?.receive(jsonDecode(jsonEncode(m)) as Map<String, Object?>);
          return devices.containsKey(channel);
        };
      info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'make a notes file',
            model: 'anthropic/claude-haiku-5.5',
            mode: AgentMode.ask,
          );
      devices = {1: _Device(info.id), 2: _Device(info.id)};
    });

    tearDown(() async {
      mirror.dispose();
      container.dispose();
      await db.close();
    });

    var nextId = 0;
    void act(int channel, String kind, [Map<String, Object?> args = const {}]) =>
        mirror.receive(channel, {'t': Tunnel.act, 'id': ++nextId, 's': info.id, 'kind': kind, 'args': args});

    test('the followed set tracks open, close and a dropped channel (the sidebar\'s devices icon)', () async {
      Set<String> followed() => container.read(remoteFollowedProvider);
      mirror
        ..receive(1, {'t': Tunnel.open, 's': info.id})
        ..receive(2, {'t': Tunnel.open, 's': info.id});
      await Future<void>.delayed(Duration.zero);
      expect(followed(), {info.id});
      mirror.receive(1, {'t': Tunnel.close, 's': info.id});
      await Future<void>.delayed(Duration.zero);
      expect(followed(), {info.id});
      mirror.channelClosed(2);
      await Future<void>.delayed(Duration.zero);
      expect(followed(), isEmpty);
    });

    test('devices list the sessions, follow one and drive it on the host', () async {
      mirror.receive(1, {'t': Tunnel.list});
      final listed = devices[1]!.lists.single;
      expect(listed['host'], 'Mac');
      expect(listed['projects'], [
        {'id': 'p1', 'name': 'Counter'},
      ]);
      final session = (listed['sessions']! as List).single as Map<String, Object?>;
      expect(CodeSessionInfo.fromJson(session).title, info.title);

      // Two devices follow the same session at once.
      mirror
        ..receive(1, {'t': Tunnel.open, 's': info.id})
        ..receive(2, {'t': Tunnel.open, 's': info.id});
      final phone = devices[1]!;
      final browser = devices[2]!;

      // The command waits for approval on the host; both devices show the card.
      await _until(() => phone.state.session.transcript.pending, (p) => p.isNotEmpty);
      await _until(() => browser.state.session.transcript.pending, (p) => p.isNotEmpty);
      expect(phone.state.session.status, SessionStatus.needsInput);
      expect(phone.state.loaded, isTrue);

      final host = container.read(codeSessionProvider(info.id));
      expect(host.transcript.pending.single.id, phone.state.session.transcript.pending.single.id);

      act(1, MirrorAction.approve, {'scope': 'once'});
      await _until(() => browser.said, (s) => s.contains('agent:made the file'));
      expect(phone.done[nextId], isNull);
      expect(phone.said, browser.said);
      expect(phone.said, ['user:make a notes file', 'agent:made the file']);

      // A picture and a Markdown file go along; a PDF doesn't.
      act(2, MirrorAction.send, {
        'text': 'now read these',
        'files': [
          {'name': 'notes.md', 'mime': 'text/markdown', 'data': base64Encode(utf8.encode('# Notes'))},
        ],
      });
      await _until(() => phone.said, (s) => s.contains('agent:read your notes'));
      expect(phone.said.firstWhere((s) => s.startsWith('user:now read these')), contains('notes.md'));
      act(2, MirrorAction.send, {
        'text': 'and this',
        'files': [
          {'name': 'paper.pdf', 'mime': 'application/pdf', 'data': base64Encode(utf8.encode('%PDF-1.4'))},
        ],
      });
      await _until(() => browser.done[nextId], (e) => e != null);
      expect(browser.done[nextId], contains('only pictures and text files'));

      // The mode changes on the host, and the devices hear of it.
      act(1, MirrorAction.mode, {'mode': AgentMode.plan.name});
      await _until(() => browser.state.session.mode, (m) => m == AgentMode.plan);
      expect(container.read(codeSessionProvider(info.id)).mode, AgentMode.plan);

      // A device that left gets nothing more.
      mirror.channelClosed(1);
      final before = phone.said.length;
      act(2, MirrorAction.send, {'text': 'one more'});
      await _until(() => browser.said, (s) => s.contains('user:one more'));
      expect(phone.said, hasLength(before));
    });

    test('an unknown session or action is refused', () async {
      devices[3] = _Device('nope');
      mirror.receive(3, {'t': Tunnel.open, 's': 'nope'});
      expect(devices[3]!.state.gone, isNotNull);
      mirror.receive(1, {'t': Tunnel.act, 'id': 7, 's': 'nope', 'kind': MirrorAction.stop});
      await _until(() => devices[1]!.done.containsKey(7), (v) => v);
      expect(devices[1]!.done[7], isNotNull);
      act(1, 'format_disk');
      await _until(() => devices[1]!.done.containsKey(nextId), (v) => v);
      expect(devices[1]!.done[nextId], contains('Unknown action'));
    });
  });
}
