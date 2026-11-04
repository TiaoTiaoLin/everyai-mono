import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plays a recorded conversation with a coding CLI as the CLI's side of a
/// [LineChannel], for driver tests without the CLI.
///
/// Each line of the script is `{"dir": "in" | "out", "msg": {…}}`: `in` is
/// what the agent sent us, `out` what we sent it. `{"dir": "in", "raw": "…"}`
/// is a line that isn't JSON (a log line on stdout), and `{"dir": "eof"}` is the
/// agent going away. The `in` lines play as soon as the `out` lines before
/// them have been sent, with no delays.
///
/// What we send must match the next `out` line: object key order doesn't
/// count, a request's `id` is learned (the `in` reply to it gets our id),
/// and the strings `{{any}}`, `{{cwd}}` and `{{session}}` match anything;
/// the last two keep what they matched and stand for it in later `in`
/// lines. A mismatch fails with the script's line number and the first path
/// that differs.
final class ReplayChannel implements LineChannel {
  ReplayChannel(String script) : _steps = _parse(script) {
    _play();
  }

  factory ReplayChannel.file(String path) => ReplayChannel(File(path).readAsStringSync());

  final List<_Step> _steps;
  var _at = 0;
  final _lines = StreamController<String>();
  final _ids = <Object, Object>{};
  final _bound = <String, Object?>{};
  final _finished = Completer<void>();
  final failures = <TestFailure>[];

  /// Everything we sent, in order.
  final sent = <Map<String, Object?>>[];

  @override
  Stream<String> get lines => _lines.stream;

  @override
  String get lastError => '';

  /// Completes once every line of the script has played.
  Future<void> get finished => _finished.future;

  /// Fails when something didn't match or `out` lines are still unsent.
  void expectFinished() {
    if (failures.isNotEmpty) throw failures.first;
    if (_at < _steps.length) {
      throw TestFailure('Replay line ${_steps[_at].line}: still waiting for ${jsonEncode(_steps[_at].msg)}');
    }
  }

  @override
  void send(String line) {
    final actual = jsonDecode(line) as Map<String, Object?>;
    sent.add(actual);
    if (_at >= _steps.length) _fail('Replay: sent after the script ended: ${jsonEncode(actual)}');
    if (_steps[_at].dir != 'out') _fail('Replay line ${_steps[_at].line}: unexpected message ${jsonEncode(actual)}');
    final step = _steps[_at];
    final expected = step.msg!;
    if (_diff(expected, actual, r'$', top: true) case final path?) {
      _fail(
        'Replay line ${step.line}: differs at $path\n  expected ${jsonEncode(expected)}\n  sent     ${jsonEncode(actual)}',
      );
    }
    if (expected['method'] != null && expected['id'] != null && actual['id'] != null) {
      _ids[expected['id']!] = actual['id']!;
    }
    _at++;
    _play();
  }

  @override
  Future<void> close() async {
    if (!_lines.isClosed) await _lines.close();
  }

  Never _fail(String why) {
    final f = TestFailure(why);
    failures.add(f);
    throw f;
  }

  void _play() {
    while (_at < _steps.length && _steps[_at].dir != 'out') {
      final step = _steps[_at++];
      if (step.dir == 'eof') {
        unawaited(close());
        break;
      }
      if (step.raw case final raw?) {
        _lines.add(raw);
        continue;
      }
      final msg = _substitute(step.msg!) as Map<String, Object?>;
      // A reply to one of our requests carries the id we used.
      final ours = msg['method'] == null ? _ids[msg['id']] : null;
      if (ours != null) msg['id'] = ours;
      _lines.add(jsonEncode(msg));
    }
    if (_at >= _steps.length && !_finished.isCompleted) _finished.complete();
  }

  Object? _substitute(Object? v) => switch (v) {
    '{{cwd}}' || '{{session}}' when _bound.containsKey(v) => _bound[v],
    final Map<String, Object?> m => {for (final e in m.entries) e.key: _substitute(e.value)},
    final List<Object?> l => [for (final x in l) _substitute(x)],
    _ => v,
  };

  /// The first path where [actual] doesn't match [expected], or null.
  String? _diff(Object? expected, Object? actual, String path, {bool top = false}) {
    if (expected == '{{any}}') return null;
    if (expected == '{{cwd}}' || expected == '{{session}}') {
      if (!_bound.containsKey(expected)) {
        _bound[expected! as String] = actual;
        return null;
      }
      return _bound[expected] == actual ? null : path;
    }
    if (expected is Map<String, Object?>) {
      if (actual is! Map<String, Object?>) return path;
      final keys = {...expected.keys, ...actual.keys};
      for (final k in keys) {
        // Request ids are ours to pick.
        if (top && k == 'id' && expected['method'] != null) {
          if (expected.containsKey('id') != actual.containsKey('id')) return '$path.id';
          continue;
        }
        if (!expected.containsKey(k) || !actual.containsKey(k)) return '$path.$k';
        if (_diff(expected[k], actual[k], '$path.$k') case final p?) return p;
      }
      return null;
    }
    if (expected is List<Object?>) {
      if (actual is! List<Object?> || actual.length != expected.length) return path;
      for (var i = 0; i < expected.length; i++) {
        if (_diff(expected[i], actual[i], '$path[$i]') case final p?) return p;
      }
      return null;
    }
    return expected == actual ? null : path;
  }

  static List<_Step> _parse(String script) {
    final out = <_Step>[];
    final lines = const LineSplitter().convert(script);
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trim();
      if (l.isEmpty || l.startsWith('//')) continue;
      final j = jsonDecode(l) as Map<String, Object?>;
      out.add(_Step(i + 1, j['dir']! as String, j['msg'] as Map<String, Object?>?, j['raw'] as String?));
    }
    return out;
  }
}

final class _Step {
  const _Step(this.line, this.dir, this.msg, this.raw);
  final int line;
  final String dir;
  final Map<String, Object?>? msg;
  final String? raw;
}
