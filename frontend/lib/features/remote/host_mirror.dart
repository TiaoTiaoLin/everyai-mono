import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachments/attachment.dart';
import '../code/code_providers.dart'
    show CodeSessionState, codeProjectsProvider, codeSessionProvider, codeSessionsProvider, codeStatusesProvider;
import '../code/domain/agent_mode.dart';
import '../code/domain/code_session.dart';
import '../code/domain/permissions.dart';
import '../code/domain/questions.dart';
import '../code/domain/transcript.dart';
import '../code/harness/events.dart';
import 'domain/remote_protocol.dart';

/// Sends one message to the device on a channel; false when it isn't connected.
typedef MirrorSend = bool Function(int channel, Map<String, Object?> message);

/// Files a device may attach to a message: pictures and text (Markdown, code).
const mirroredFileKinds = {AttachmentKind.image, AttachmentKind.text};

/// [event] as it goes to a mirroring device: the agent-server JSON, with a
/// spilled result's preview in place of the whole output.
Map<String, Object?> wireEvent(HarnessEvent event) => switch (event) {
  ToolResult(:final raw, :final observation) when raw['kind'] == 'ObservationEvent' => {
    ...raw,
    'observation': observation,
  },
  _ => event.raw,
};

/// What a mirroring device needs beside the transcript: the parts of
/// [CodeSessionState] it can't fold from events, and the approval card's
/// remember patterns and danger flags (worked out by this host's rules).
Map<String, Object?> mirrorState(
  CodeSessionState state, {
  required List<String>? remember,
  required Map<String, String> flags,
  Map<String, String> rememberBy = const {},
  bool perCall = false,
}) => {
  'mode': state.mode.name,
  'queued': [for (final q in state.queued) q.text],
  'connected': state.connected,
  'error': ?state.error,
  'subagent_needs_input': state.subagentNeedsInput,
  'remember': ?remember,
  'flags': flags,
  'remember_by': rememberBy,
  'per_call': perCall,
  'decided': state.decided,
};

/// The host side of mirroring: devices list this computer's Code sessions,
/// follow one as it runs, and send the user's actions, which run on the
/// session's own controller here (the same one the desktop window uses). So
/// any number of devices and the desktop drive one session together, and
/// nothing about permissions is decided on a device.
final class HostMirror {
  HostMirror(this._ref, {required this.hostName});

  final Ref _ref;
  final String hostName;

  /// Seals a message to a device's channel (`HostBridge.send`); false when it
  /// isn't connected. Set right after construction (the bridge needs [receive]).
  late final MirrorSend send;

  /// Channels that asked for the session list.
  final _listeners = <int>{};
  final _watches = <int, Map<String, _Watch>>{};
  final _lastList = <int, String>{};
  Timer? _listTimer;
  Timer? _listSoon;
  ProviderSubscription<Object?>? _sessionsSub;
  ProviderSubscription<Object?>? _statusesSub;

  void receive(int channel, Map<String, Object?> m) {
    final s = m['s'];
    switch (m['t']) {
      case Tunnel.list:
        _listeners.add(channel);
        _lastList.remove(channel);
        _watchList();
        _sendList(channel);
      case Tunnel.open when s is String:
        _open(channel, s);
      case Tunnel.close when s is String:
        _watches[channel]?.remove(s)?.close();
      case Tunnel.act:
        unawaited(_act(channel, m));
    }
  }

  /// The device on [channel] left: stop everything it followed.
  void channelClosed(int channel) {
    _listeners.remove(channel);
    _lastList.remove(channel);
    for (final w in _watches.remove(channel)?.values ?? const <_Watch>[]) {
      w.close();
    }
    if (_listeners.isEmpty) _unwatchList();
  }

  void dispose() {
    for (final channel in [..._watches.keys, ..._listeners]) {
      channelClosed(channel);
    }
    _unwatchList();
  }

  // ---------------------------------------------------------------- session list

  void _watchList() {
    if (_listTimer != null) return;
    _sessionsSub = _ref.listen(codeSessionsProvider, (_, _) => _listChanged());
    _statusesSub = _ref.listen(codeStatusesProvider, (_, _) => _listChanged());
    // Open sessions' statuses live in their controllers; read them now and then.
    _listTimer = Timer.periodic(const Duration(seconds: 2), (_) => _listChanged());
  }

  void _unwatchList() {
    _listTimer?.cancel();
    _listTimer = null;
    _listSoon?.cancel();
    _listSoon = null;
    _sessionsSub?.close();
    _statusesSub?.close();
    _sessionsSub = _statusesSub = null;
  }

  void _listChanged() {
    _listSoon ??= Timer(const Duration(milliseconds: 100), () {
      _listSoon = null;
      for (final channel in [..._listeners]) {
        _sendList(channel);
      }
    });
  }

  SessionStatus _statusOf(CodeSessionInfo s) => _ref.exists(codeSessionProvider(s.id))
      ? _ref.read(codeSessionProvider(s.id)).status
      : _ref.read(codeStatusesProvider)[s.id] ?? SessionStatus.idle;

  void _sendList(int channel) {
    final message = {
      't': Tunnel.sessions,
      'host': hostName,
      'projects': [
        for (final p in _ref.read(codeProjectsProvider)) {'id': p.id, 'name': p.name},
      ],
      'sessions': [
        for (final s in _ref.read(codeSessionsProvider)) {...s.toJson(), 'status': _statusOf(s).name},
      ],
    };
    final encoded = jsonEncode(message);
    if (_lastList[channel] == encoded) return;
    if (send(channel, message)) _lastList[channel] = encoded;
  }

  // ---------------------------------------------------------------- one session

  void _open(int channel, String id) {
    final info = _ref.read(codeSessionsProvider.notifier).byId(id);
    if (info == null) {
      send(channel, {'t': Tunnel.gone, 's': id, 'message': "This session isn't on the computer any more."});
      return;
    }
    final watches = _watches.putIfAbsent(channel, () => {});
    watches.remove(id)?.close();
    final w = watches[id] = _Watch(channel, id, send);
    final provider = codeSessionProvider(id);
    // Listening keeps the session connected here while a device follows it.
    w.stateSub = _ref.listen<CodeSessionState>(provider, (_, _) => w.stateSoon(() => _state(id)));
    final controller = _ref.read(provider.notifier);
    // The log and the tap in the same turn: nothing falls between them.
    w.sendLog(controller.mirrorEvents);
    w.tap = controller.mirrorTap.listen((e) => e == null ? w.sendLog(controller.mirrorEvents) : w.add(e));
    w.sendState(_state(id));
  }

  Map<String, Object?> _state(String id) {
    final provider = codeSessionProvider(id);
    final state = _ref.read(provider);
    final controller = _ref.read(provider.notifier);
    return mirrorState(
      state,
      remember: controller.rememberable(),
      rememberBy: controller.rememberBy(),
      perCall: controller.perCall,
      flags: {
        for (final c in state.transcript.pending)
          if (controller.policy.decide(c, state.mode) case Decision(source: DecisionSource.dangerous, :final why))
            c.id: why,
      },
    );
  }

  Future<void> _act(int channel, Map<String, Object?> m) async {
    final id = m['id'];
    final s = m['s'];
    final args = switch (m['args']) {
      final Map<String, Object?> a => a,
      _ => const <String, Object?>{},
    };
    String? error;
    try {
      if (s is! String || _ref.read(codeSessionsProvider.notifier).byId(s) == null) {
        throw const MirrorRefusal("This session isn't on the computer any more.");
      }
      final c = _ref.read(codeSessionProvider(s).notifier);
      String text() => args['text'] as String? ?? '';
      switch (m['kind']) {
        case MirrorAction.send:
          await c.sendTyped(text(), files: _files(args['files']));
        case MirrorAction.steer:
          await c.steer(text(), files: _files(args['files']));
        case MirrorAction.stop:
          await c.stop();
        case MirrorAction.approve:
          await c.approve(ApprovalScope.values.asNameMap()[args['scope']] ?? ApprovalScope.once, _ids(args));
        case MirrorAction.deny:
          await c.deny(args['reason'] as String?, _ids(args));
        case MirrorAction.answer:
          final item = _ref
              .read(codeSessionProvider(s))
              .transcript
              .items
              .whereType<QuestionItem>()
              .where((q) => q.call.id == args['call'] && q.answers == null)
              .firstOrNull;
          if (item == null) throw const MirrorRefusal('Those questions were answered already.');
          await c.answer(item, [
            for (final a in args['answers'] as List<Object?>? ?? const [])
              if (a case {'selected': final List<Object?> selected, 'other': final String other})
                QuestionAnswer(selected: {...selected.whereType<int>()}, other: other),
          ]);
        case MirrorAction.mode:
          final mode = AgentMode.values.asNameMap()[args['mode']];
          if (mode == null) throw const MirrorRefusal('Unknown mode.');
          await c.setMode(mode);
        case MirrorAction.build:
          await c.startBuilding();
        case MirrorAction.retry:
          await c.retry();
        case MirrorAction.retryNow:
          await c.retryNow();
        case MirrorAction.unqueue:
          final i = args['index'];
          if (i is int && i >= 0 && i < _ref.read(codeSessionProvider(s)).queued.length) c.unqueue(i);
        default:
          throw MirrorRefusal('Unknown action ${m['kind']}.');
      }
    } on Object catch (e) {
      error = e is MirrorRefusal ? e.message : '$e';
    }
    send(channel, {'t': Tunnel.done, 'id': id, 'error': ?error});
  }

  /// The calls a device answered one by one (`call_ids`), or null for all.
  static List<String>? _ids(Map<String, Object?> args) => switch (args['call_ids']) {
    final List<Object?> ids => [...ids.whereType<String>()],
    _ => null,
  };

  /// A device's attachments, checked as a picked file is: pictures and text only.
  static List<Attachment> _files(Object? raw) {
    if (raw is! List<Object?>) return const [];
    final files = <Attachment>[];
    var total = 0;
    for (final (i, f) in raw.indexed) {
      if (f case {'name': final String name, 'data': final String data}) {
        final bytes = base64Decode(data);
        total += bytes.length;
        if (total > maxMessageBytes) throw const MirrorRefusal('The attachments are too large together.');
        final read = Attachment.from(
          id: 'remote-${DateTime.now().microsecondsSinceEpoch}-$i',
          name: name,
          bytes: bytes,
          mime: f['mime'] as String?,
        );
        final a = read.attachment;
        if (a == null) throw MirrorRefusal(read.error ?? "Couldn't read $name.");
        if (!mirroredFileKinds.contains(a.kind)) {
          throw MirrorRefusal('$name: only pictures and text files can be sent from this device.');
        }
        files.add(a);
      }
    }
    return files;
  }
}

/// An action the host turned down, with the reason to show.
final class MirrorRefusal implements Exception {
  const MirrorRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One device following one session.
final class _Watch {
  _Watch(this.channel, this.session, this.send);

  final int channel;
  final String session;
  final MirrorSend send;
  ProviderSubscription<CodeSessionState>? stateSub;
  StreamSubscription<HarnessEvent?>? tap;

  /// Events waiting for the next send (deltas come many at a time).
  final _buffer = <Map<String, Object?>>[];
  Timer? _flush;
  Timer? _stateTimer;
  String _lastState = '';
  bool _closed = false;

  /// The whole log, from a fresh fold: what was buffered is in it already.
  void sendLog(List<HarnessEvent> log) {
    _buffer.clear();
    _flush?.cancel();
    _flush = null;
    send(channel, {'t': Tunnel.reset, 's': session});
    // Parts of about a megabyte, so one message never holds the whole history.
    var chunk = <Map<String, Object?>>[];
    var size = 0;
    for (final e in log) {
      final wire = wireEvent(e);
      if (wire.isEmpty) continue;
      final n = jsonEncode(wire).length;
      if (chunk.isNotEmpty && size + n > 1 << 20) {
        send(channel, {'t': Tunnel.events, 's': session, 'events': chunk});
        chunk = [];
        size = 0;
      }
      chunk.add(wire);
      size += n;
    }
    if (chunk.isNotEmpty) send(channel, {'t': Tunnel.events, 's': session, 'events': chunk});
  }

  void add(HarnessEvent e) {
    if (_closed) return;
    final wire = wireEvent(e);
    if (wire.isEmpty) return;
    _buffer.add(wire);
    _flush ??= Timer(const Duration(milliseconds: 30), _sendBuffer);
  }

  void _sendBuffer() {
    _flush = null;
    if (_buffer.isEmpty || _closed) return;
    send(channel, {
      't': Tunnel.events,
      's': session,
      'events': [..._buffer],
    });
    _buffer.clear();
  }

  /// State changes come with every event; one send per short while.
  void stateSoon(Map<String, Object?> Function() read) {
    _stateTimer ??= Timer(const Duration(milliseconds: 80), () {
      _stateTimer = null;
      if (!_closed) sendState(read());
    });
  }

  void sendState(Map<String, Object?> state) {
    final encoded = jsonEncode(state);
    if (encoded == _lastState) return;
    // Events first, so the state never runs ahead of the transcript.
    _flush?.cancel();
    _sendBuffer();
    if (send(channel, {'t': Tunnel.state, 's': session, ...state})) _lastState = encoded;
  }

  void close() {
    _closed = true;
    _flush?.cancel();
    _stateTimer?.cancel();
    unawaited(tap?.cancel());
    stateSub?.close();
  }
}
