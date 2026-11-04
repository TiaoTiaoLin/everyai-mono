import 'package:every_ai/core/net/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('requests wait until the server answers /v1/ping, and the banner states follow', () async {
    var pings = 0;
    final paths = <String>[];
    final client = ApiClient(
      baseUrl: Uri.parse('https://api.test/'),
      waitForServer: true,
      wakeBackoff: Duration.zero,
      client: MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path == '/v1/ping') {
          pings++;
          if (pings == 1) throw http.ClientException('Connection refused');
          if (pings == 2) return http.Response('starting', 503);
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"data":[]}', 200);
      }),
    );
    final seen = <ServerStatus>[];
    client.status.listen(seen.add);

    final body = await client.getJson('v1/models');

    expect(body, {'data': <Object?>[]});
    expect(paths, ['/v1/ping', '/v1/ping', '/v1/ping', '/v1/models']);
    await Future<void>.delayed(Duration.zero);
    expect(seen, [ServerStatus.waking, ServerStatus.online]);

    // Online now: the next request goes straight through.
    await client.getJson('v1/models');
    expect(paths.last, '/v1/models');
    expect(paths.where((p) => p == '/v1/ping'), hasLength(3));
  });

  test('a server that answers at once shows no banner', () async {
    final client = ApiClient(
      baseUrl: Uri.parse('https://api.test/'),
      waitForServer: true,
      client: MockClient((req) async => http.Response('{}', 200)),
    );
    final seen = <ServerStatus>[];
    client.status.listen(seen.add);
    await client.getJson('v1/me');
    await Future<void>.delayed(Duration.zero);
    expect(seen, isEmpty);
  });
}
