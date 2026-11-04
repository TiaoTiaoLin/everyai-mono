import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'replay_transport.dart';

/// An HTTP client that plays a recorded server through a [ReplayChannel],
/// for drivers that talk to a local server (OpenCode's `serve`).
///
/// Each request we make is an `out` line `{"id", "method", "path",
/// "query"?, "body"?}` (the body decoded from JSON); its reply is the `in`
/// line `{"id", "status", "body"?}` with the same id. A `GET /api/event`
/// gets no reply line: it opens a server-sent event stream that every later
/// `in` line `{"event": {…}}` is written to as a `data:` frame, until an
/// `in` line `{"sse": "drop"}` ends it (the next `GET /api/event` opens a new
/// one).
final class ReplayHttpClient extends http.BaseClient {
  ReplayHttpClient(this.channel) {
    channel.lines.listen(_onLine);
  }

  factory ReplayHttpClient.script(String script) => ReplayHttpClient(ReplayChannel(script));

  final ReplayChannel channel;

  /// Every request made, in order.
  final requests = <http.BaseRequest>[];
  final _replies = <Object, Completer<Map<String, Object?>>>{};
  StreamController<List<int>>? _events;
  var _next = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = request is http.Request && request.body.isNotEmpty ? jsonDecode(request.body) : null;
    final id = ++_next;
    final msg = <String, Object?>{
      'id': id,
      'method': request.method,
      'path': request.url.path,
      if (request.url.queryParameters.isNotEmpty) 'query': request.url.queryParameters,
      'body': ?body,
    };
    if (request.method == 'GET' && request.url.path == '/api/event') {
      // Closed by a `{"sse": "drop"}` line or [close].
      // ignore: close_sinks
      final events = _events = StreamController<List<int>>();
      channel.send(jsonEncode(msg));
      return http.StreamedResponse(events.stream, 200, headers: {'content-type': 'text/event-stream'});
    }
    final reply = _replies[id] = Completer<Map<String, Object?>>();
    channel.send(jsonEncode(msg));
    final r = await reply.future;
    final text = r.containsKey('body') ? jsonEncode(r['body']) : '';
    return http.StreamedResponse(
      Stream.value(utf8.encode(text)),
      (r['status'] as num? ?? 200).toInt(),
      headers: {'content-type': 'application/json'},
    );
  }

  void _onLine(String line) {
    final msg = jsonDecode(line) as Map<String, Object?>;
    if (msg.containsKey('event')) {
      _events?.add(utf8.encode('data: ${jsonEncode(msg['event'])}\n\n'));
    } else if (msg['sse'] == 'drop') {
      unawaited(_events?.close());
      _events = null;
    } else if (_replies.remove(msg['id']) case final c?) {
      c.complete(msg);
    }
  }

  @override
  void close() {
    unawaited(_events?.close());
    _events = null;
  }
}
