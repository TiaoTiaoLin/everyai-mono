// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

import '../../domain/agent_mode.dart';
import '../../domain/compaction.dart' show userTextOf;
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../../harness/session_processes.dart' show unregisterDriverRoot;
import '../../panes/pty.dart';
import '../driver_events.dart';
import '../driver_process.dart' show trackDriverClose, untrackDriverClose;

/// A coding CLI running in a pseudo-terminal, with no way to read what it does: the session shows what the user
/// sends and one notice, nothing else. It never reports `running` (the controller queues messages while it does and
/// the app can't tell when the CLI is done), only `idle`, then `finished` or `error` when the process exits.
///
/// For the session lane: [terminal] is what the Terminal tab renders (`TerminalView(terminal)`) instead of starting
/// a shell of its own, [pty] is its process (pid for the Processes pane), and [briefingText] is the session text to
/// show; nothing is pasted into the CLI by itself. Messages go to the CLI as the user typed them (the mode and
/// context notes the controller adds are cut off); the transcript keeps the full text.
final class TerminalSession implements HarnessSession {
  TerminalSession({
    required this.id,
    required this.label,
    required this.pty,
    required this.sessionTag,
    this.briefing,
    this.settle = defaultSettle,
  }) {
    terminal.onOutput = (data) => pty.write(Uint8List.fromList(utf8.encode(data)));
    terminal.onResize = (cols, rows, _, _) => pty.resize(rows, cols);
    _output = pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      terminal.write(chunk);
      if (!_drawn.isCompleted) _drawn.complete();
    });
    _emit(stateEvent(_nextId(), ExecutionStatus.idle));
    trackDriverClose(close);
    unawaited(pty.exitCode.then(_exited));
  }

  @override
  final String id;
  final String label;
  final ShellPty pty;
  final String sessionTag;

  /// Reads the session text (null: none); the driver passes the briefing file's reader.
  final Future<String?> Function()? briefing;

  /// The wait between the paste and Return (replaced in tests).
  final Future<void> Function() settle;

  static Future<void> defaultSettle() => Future<void>.delayed(const Duration(milliseconds: 150));

  /// The screen and scrollback; it also tracks whether the CLI asked for bracketed paste.
  final terminal = Terminal(maxLines: 5000);

  final _history = <HarnessEvent>[];
  final _live = StreamController<HarnessEvent>.broadcast(sync: true);
  late final StreamSubscription<String> _output;
  var _n = 0;
  var _noticed = false;
  var _closed = false;
  var _exitedAlready = false;
  final _drawn = Completer<void>();

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
    if (_exitedAlready) {
      _emit(HarnessEvent.decode(_message('agent', 'assistant', '$label has ended; start a new session to go on.')));
      return;
    }
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
    // Nothing can be typed before the CLI has drawn: it may not have its input mode (or bracketed paste) on yet.
    if (!_drawn.isCompleted) await _drawn.future;
    if (_closed || _exitedAlready) return;
    final typed = userTextOf(text);
    // Brackets only when the CLI asked for them; otherwise a newline would submit half a prompt.
    final bracketed = terminal.bracketedPasteMode;
    terminal.paste(bracketed ? typed : typed.replaceAll(RegExp(r'\s*\n\s*'), ' '));
    // Return a moment later: in the same read as the paste, some TUIs take it as part of the pasted text.
    await settle();
    if (!_closed && !_exitedAlready) pty.write(Uint8List.fromList([13]));
  }

  @override
  Future<void> interrupt() async {
    if (!_closed && !_exitedAlready) pty.write(Uint8List.fromList([3]));
  }

  void _exited(int code) {
    if (_closed) return;
    _exitedAlready = true;
    unregisterDriverRoot(sessionTag, pty.pid);
    untrackDriverClose(close);
    if (!_drawn.isCompleted) _drawn.complete();
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
    untrackDriverClose(close);
    if (!_exitedAlready) pty.kill();
    if (!_drawn.isCompleted) _drawn.complete();
    await _output.cancel();
    await _live.close();
  }
}
