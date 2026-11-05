import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'sse.dart';

/// Whether the backend answers. A server that scaled to zero or is restarting takes a while to come up.
enum ServerStatus {
  /// Answered; requests go straight through.
  online,

  /// Didn't answer yet; requests wait (the app shows "waking up").
  waking,

  /// Didn't come up within [ApiClient.wakeTimeout]; the next request tries again.
  unreachable,
}

/// Supplies bearer tokens for authenticated requests. Implemented by the auth feature.
abstract interface class AccessTokenSource {
  /// The current access token, or null when signed out or bypassed.
  Future<String?> accessToken();

  /// Called once after a 401. Returns a fresh token, or null if the session is gone.
  Future<String?> refreshAccessToken();
}

/// The one HTTP entry point for the backend. Create it once (see `apiClientProvider`)
/// and reuse it so connections, HTTP/2 sessions and QUIC state are pooled.
final class ApiClient {
  ApiClient({
    required this.baseUrl,
    required http.Client client,
    AccessTokenSource? tokens,
    this.waitForServer = false,
    this.wakeBackoff = const Duration(milliseconds: 500),
  }) : _client = client, // ignore: prefer_initializing_formals
       _tokens = tokens; // ignore: prefer_initializing_formals

  final Uri baseUrl;
  final http.Client _client;
  final AccessTokenSource? _tokens;

  /// Hold every request until the server answers `GET /v1/ping` (the app's
  /// client; tests talk to their fakes directly).
  final bool waitForServer;

  /// The first pause between pings while the server starts; it doubles up to 4 s.
  final Duration wakeBackoff;

  /// How long requests wait for a server that is starting before they fail.
  static const wakeTimeout = Duration(seconds: 90);

  bool _online = false;
  Future<void>? _waking;
  ServerStatus? _shown;
  final _status = StreamController<ServerStatus>.broadcast();

  /// Changes of [ServerStatus]; nothing is sent while the server answers at once.
  Stream<ServerStatus> get status => _status.stream;

  /// Completes when the server answers, polling with backoff while it starts.
  /// Throws a [NetworkError] after [wakeTimeout].
  Future<void> awaitOnline() {
    if (_online) return Future.value();
    return _waking ??= _wake().whenComplete(() => _waking = null);
  }

  void _show(ServerStatus status) {
    if (_shown == status || _status.isClosed) return;
    _shown = status;
    _status.add(status);
  }

  Future<void> _wake() async {
    final deadline = DateTime.now().add(wakeTimeout);
    var delay = wakeBackoff;
    while (true) {
      try {
        final res = await _client.send(http.Request('GET', resolve('v1/ping'))).timeout(const Duration(seconds: 10));
        await res.stream.drain<void>();
        // A 5xx here is a proxy or a server still starting; anything else is the server itself.
        if (res.statusCode < 500) {
          _online = true;
          if (_shown != null) _show(ServerStatus.online);
          return;
        }
      } on Object {
        // Not up yet (refused, reset, timed out).
      }
      _show(ServerStatus.waking);
      if (DateTime.now().isAfter(deadline)) {
        _show(ServerStatus.unreachable);
        throw const NetworkError("The EveryAI server didn't come online. Check your connection and try again.");
      }
      await Future<void>.delayed(delay);
      if (delay < const Duration(seconds: 4)) delay = delay * 2 + const Duration(milliseconds: 1);
    }
  }

  static const jsonTimeout = Duration(seconds: 20);

  /// LLM responses can take minutes; this bounds the wait for the *first* byte.
  static const generationTimeout = Duration(minutes: 3);

  Uri resolve(String path) => baseUrl.resolve(path.startsWith('/') ? path.substring(1) : path);

  Future<void> ping() async {
    final res = await _send('GET', 'v1/ping', timeout: const Duration(seconds: 5));
    await _readBody(res);
  }

  /// GET and decode a JSON object response.
  Future<Map<String, Object?>> getJson(
    String path, {
    bool authenticated = false,
    Duration timeout = jsonTimeout,
  }) async {
    final res = await _send('GET', path, authenticated: authenticated, timeout: timeout);
    return _decodeObject(await _readBody(res));
  }

  /// GET and decode a JSON array response.
  Future<List<Object?>> getJsonList(String path, {bool authenticated = false, Duration timeout = jsonTimeout}) async {
    final res = await _send('GET', path, authenticated: authenticated, timeout: timeout);
    try {
      final decoded = jsonDecode(utf8.decode(await _readBody(res)));
      if (decoded is List<Object?>) return decoded;
      throw const ProtocolError('Expected a JSON array.');
    } on FormatException {
      throw const ProtocolError('The server returned malformed JSON.');
    }
  }

  /// DELETE, ignoring any body.
  Future<void> delete(String path, {bool authenticated = false}) async {
    final res = await _send('DELETE', path, authenticated: authenticated, timeout: jsonTimeout);
    await _readBody(res);
  }

  /// POST a JSON body and decode a JSON object response.
  Future<Map<String, Object?>> postJson(
    String path,
    Map<String, Object?> body, {
    bool authenticated = false,
    Duration timeout = jsonTimeout,
    Future<void>? cancel,
    Map<String, String> headers = const {},
  }) async {
    final res = await _send(
      'POST',
      path,
      json: body,
      authenticated: authenticated,
      timeout: timeout,
      cancel: cancel,
      headers: headers,
    );
    return _decodeObject(await _readBody(res, cancel: cancel));
  }

  /// PUT a JSON body and decode a JSON object response.
  Future<Map<String, Object?>> putJson(
    String path,
    Map<String, Object?> body, {
    bool authenticated = false,
    Duration timeout = jsonTimeout,
  }) async {
    final res = await _send('PUT', path, json: body, authenticated: authenticated, timeout: timeout);
    return _decodeObject(await _readBody(res));
  }

  static Map<String, Object?> _decodeObject(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?>) return decoded;
      throw const ProtocolError('Expected a JSON object.');
    } on FormatException {
      throw const ProtocolError('The server returned malformed JSON.');
    }
  }

  /// POST JSON and return the raw body (e.g. generated images).
  Future<({Uint8List bytes, String contentType})> postForBytes(
    String path,
    Map<String, Object?> body, {
    bool authenticated = false,
    Duration timeout = generationTimeout,
    Future<void>? cancel,
  }) async {
    final res = await _send('POST', path, json: body, authenticated: authenticated, timeout: timeout, cancel: cancel);
    final bytes = await _readBody(res, cancel: cancel);
    return (bytes: bytes, contentType: res.headers['content-type'] ?? 'application/octet-stream');
  }

  /// POST JSON and consume a `text/event-stream` response.
  Stream<SseEvent> postSse(
    String path,
    Map<String, Object?> body, {
    bool authenticated = false,
    Duration timeout = generationTimeout,
    Future<void>? cancel,
    Map<String, String> headers = const {},
  }) async* {
    final res = await _send(
      'POST',
      path,
      json: body,
      authenticated: authenticated,
      timeout: timeout,
      cancel: cancel,
      headers: {...headers, 'Accept': 'text/event-stream', 'Cache-Control': 'no-cache'},
    );
    if (res.statusCode ~/ 100 != 2) {
      await _readBody(res); // throws a typed error
      return;
    }
    try {
      yield* res.stream.transform(const SseDecoder());
    } on http.RequestAbortedException {
      throw const CancelledError();
    } on http.ClientException catch (e) {
      throw NetworkError(e.message);
    }
  }

  Future<http.StreamedResponse> _send(
    String method,
    String path, {
    Map<String, Object?>? json,
    bool authenticated = false,
    required Duration timeout,
    Future<void>? cancel,
    Map<String, String> headers = const {},
    bool isRetry = false,
  }) async {
    if (waitForServer) await awaitOnline();
    final request = http.AbortableRequest(method, resolve(path), abortTrigger: cancel)..headers.addAll(headers);
    if (json != null) {
      request
        ..headers['Content-Type'] = 'application/json; charset=utf-8'
        ..bodyBytes = utf8.encode(jsonEncode(json));
    }
    if (authenticated) {
      final token = isRetry ? await _tokens?.refreshAccessToken() : await _tokens?.accessToken();
      if (token == null) throw const UnauthorizedError();
      request.headers['Authorization'] = 'Bearer $token';
    }

    final http.StreamedResponse res;
    try {
      res = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const TimeoutError();
    } on http.RequestAbortedException {
      throw const CancelledError();
    } on http.ClientException catch (e) {
      // The server went away (a restart, a scale-down): the next request waits for it again.
      _online = false;
      throw NetworkError(e.message);
    }

    if (res.statusCode == 401 && authenticated && !isRetry) {
      await res.stream.drain<void>();
      return _send(
        method,
        path,
        json: json,
        authenticated: true,
        timeout: timeout,
        cancel: cancel,
        headers: headers,
        isRetry: true,
      );
    }
    return res;
  }

  /// Reads the body, converting non-2xx statuses into typed [ApiError]s.
  Future<Uint8List> _readBody(http.StreamedResponse res, {Future<void>? cancel}) async {
    final Uint8List bytes;
    try {
      bytes = await res.stream.toBytes();
    } on http.RequestAbortedException {
      throw const CancelledError();
    } on http.ClientException catch (e) {
      throw NetworkError(e.message);
    }
    final status = res.statusCode;
    if (status ~/ 100 == 2) return bytes;
    if (status == 401) throw const UnauthorizedError();
    final detail = _detail(bytes);
    throw HttpStatusError(status, detail?.message ?? 'Request failed ($status).', code: detail?.code);
  }

  /// `{"message", "code"}` (backend-exp), problem documents (`detail`/`title`),
  /// `{"error": {"message"}}` (OpenAI style) and a bare `{"detail"}`.
  static ({String message, String? code})? _detail(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      final code = decoded is Map ? decoded['code'] as String? : null;
      if (decoded case {'message': final String message}) return (message: message, code: code);
      // A 422 problem: the first field's problem says more than "1 field is invalid."
      if (decoded case {'errors': [{'message': final String message} && final Map<String, Object?> first, ...]}) {
        final field = first['field'];
        return (message: field is String && field.isNotEmpty ? '$field $message' : message, code: code);
      }
      if (decoded case {'detail': final String detail}) return (message: detail, code: code);
      if (decoded case {'title': final String title}) return (message: title, code: code);
      if (decoded case {'error': {'message': final String message}}) return (message: message, code: code);
      if (decoded case {'error': final String error}) return (message: error, code: code);
    } on FormatException {
      // Not JSON; fall through.
    }
    return null;
  }

  void close() {
    _status.close();
    _client.close();
  }
}
