import '../../../core/net/api_client.dart';

/// Names a new chat from its opening exchange (`POST /v1/aux/title`).
abstract interface class ChatTitler {
  /// A short title, or null when there is none (any error, a 402, a timeout):
  /// the chat keeps its local title then.
  Future<String?> title({
    required String user,
    required String assistant,
    required String session,
    Map<String, String> headers,
  });
}

final class HttpChatTitler implements ChatTitler {
  const HttpChatTitler(this._api, {this.authenticated = false, this.timeout = const Duration(seconds: 20)});

  final ApiClient _api;
  final bool authenticated;
  final Duration timeout;

  @override
  Future<String?> title({
    required String user,
    required String assistant,
    required String session,
    Map<String, String> headers = const {},
  }) async {
    try {
      final json = await _api
          .postJson(
            'v1/aux/title',
            {
              'messages': [
                {'role': 'user', 'content': user},
                if (assistant.isNotEmpty) {'role': 'assistant', 'content': assistant},
              ],
              'session': session,
            },
            authenticated: authenticated,
            timeout: timeout,
            headers: headers,
          )
          .timeout(timeout + const Duration(seconds: 1));
      final t = json['title'];
      return t is String && t.trim().isNotEmpty ? t.trim() : null;
    } on Object {
      return null;
    }
  }
}
