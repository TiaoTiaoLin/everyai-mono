// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

import '../../domain/agent_mode.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../../harness/session_processes.dart' show unregisterDriverRoot;
import '../../panes/pty.dart';
import '../driver_events.dart';

/// A coding CLI running in a pseudo-terminal, with no way to read what it does: the session shows what the user
/// sends and one notice, nothing else. It never reports `running` (the controller queues messages while it does and
/// the app can't tell when the CLI is done), only `idle`, then `finished` or `error` when the process exits.
///
/// For the session lane: [terminal] is what the Terminal tab renders (`TerminalView(terminal)`) instead of starting
/// a shell of its own, [pty] is its process (pid for the Processes pane), and [briefingText] is the session text to
/// show; nothing is pasted into the CLI by itself. Don't prefix messages with the mode note: they go to the CLI as typed.
final class TerminalSession implements HarnessSession {
  TerminalSession({required this.id, required this.label, required this.pty, required this.sessionTag, this.briefing}) {
    terminal.onOutput = (data) => pty.write(Uint8List.fromList(utf8.encode(data)));
    terminal.onResize = (cols, rows, _, _) => pty.resize(rows, cols);
    _output = pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
    _emit(stateEvent(_nextId(), ExecutionStatus.idle));
    unawaited(pty.exitCode.then(_exited));
  }

  @override
  final String id;
  final String label;
  final ShellPty pty;
  final String sessionTag;

  /// Reads the session text (null: none); the driver passes the briefing file's reader.
  final Future<String?> Function()? briefing;

  /// The screen and scrollback; it also tracks whether the CLI asked for bracketed paste.
  final terminal = Terminal(maxLines: 5000);

  final _history = <HarnessEvent>[];
  final _live = StreamController<HarnessEvent>.broadcast(sync: true);
  late final StreamSubscription<String> _output;
  var _n = 0;
  var _noticed = false;
  var _closed = false;

  Future<String?> briefingText() async => briefing?.call();

  @override
  Stream<HarnessEvent> get events {
    late final StreamController<HarnessEvent> c;
    StreamSubscription<HarnessEvent>? sub;
    c = StreamController<HarnessEvent>(
      onListen: () {
        _history.forEach(c.add);
        sub = _live.stream.listen(c.add, onDone: c.close);
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  String _nextId() => '$id-${_n++}';

  void _emit(HarnessEvent e) {
    _history.add(e);
    if (!_live.isClosed) _live.add(e);
  }

  Map<String, Object?> _message(String source, String role, String text) => {
    'kind': 'MessageEvent',
    'id': _nextId(),
    'source': source,
    'llm_message': {
      'role': role,
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  };

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    if (_closed) return;
    _emit(HarnessEvent.decode(_message('user', 'user', text)));
    if (!_noticed) {
      _noticed = true;
      _emit(
        HarnessEvent.decode(
          _message(
            'agent',
            'assistant',
            "EveryAI can't see what $label does here. Work in the terminal tab; the session ends when $label exits.",
          ),
        ),
      );
    }
    // Brackets only when the CLI asked for them; otherwise a newline would submit half a prompt.
    final bracketed = terminal.bracketedPasteMode;
    terminal.paste(bracketed ? text : text.replaceAll(RegExp(r'\s*\n\s*'), ' '));
    // A separate write: some TUIs read a Return in the same chunk as the paste as part of it.
    pty.write(Uint8List.fromList([13]));
  }

  @override
  Future<void> interrupt() async {
    if (!_closed) pty.write(Uint8List.fromList([3]));
  }

  void _exited(int code) {
    if (_closed) return;
    if (code == 0) {
      _emit(stateEvent(_nextId(), ExecutionStatus.finished));
    } else {
      _emit(
        HarnessEvent.decode({
          'kind': 'ConversationErrorEvent',
          'id': _nextId(),
          'detail': '$label exited with code $code.',
        }),
      );
      _emit(stateEvent(_nextId(), ExecutionStatus.error));
    }
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {}
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {}
  @override
  Future<void> switchLlm(SessionSpec spec) async {}

  @override
  Future<void> rewindTo(String? head) async => throw HarnessError("$label sessions can't be rewound.");

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unregisterDriverRoot(sessionTag, pty.pid);
    pty.kill();
    await _output.cancel();
    await _live.close();
  }
}
