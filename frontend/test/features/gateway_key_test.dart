import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/summarizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late _MemoryStore store;
  late int minted;
  Future<String> mint() async => 'sk-eai-new-${++minted}';

  setUp(() {
    store = _MemoryStore();
    minted = 0;
  });

  test('moves the old Preferences key into the keychain', () async {
    final prefs = Preferences.inMemory({GatewayKeys.legacyKey: 'sk-eai-old'});
    final keys = GatewayKeys(store: store, mint: mint, legacy: prefs);
    expect(await keys.key(), 'sk-eai-old');
    expect(store.values[GatewayKeys.storeKey], 'sk-eai-old');
    expect(prefs[GatewayKeys.legacyKey], isNull);
    expect(minted, 0);
  });

  test('reads the keychain before minting, and mints once for concurrent callers', () async {
    store.values[GatewayKeys.storeKey] = 'sk-eai-kept';
    expect(await GatewayKeys(store: store, mint: mint).key(), 'sk-eai-kept');

    final fresh = GatewayKeys(store: _MemoryStore(), mint: mint);
    final both = await Future.wait([fresh.key(), fresh.key()]);
    expect(both, ['sk-eai-new-1', 'sk-eai-new-1']);
    expect(minted, 1);
  });

  test('remint replaces a refused key once, however many callers saw it', () async {
    store.values[GatewayKeys.storeKey] = 'sk-eai-revoked';
    final keys = GatewayKeys(store: store, mint: mint);
    final stale = await keys.key();
    final again = await Future.wait([keys.remint(stale), keys.remint(stale)]);
    expect(again, ['sk-eai-new-1', 'sk-eai-new-1']);
    expect(store.values[GatewayKeys.storeKey], 'sk-eai-new-1');
    // A caller still holding the old key gets the new one without another mint.
    expect(await keys.remint(stale), 'sk-eai-new-1');
    expect(minted, 1);
  });

  test('a refusal right after a mint keeps the new key', () async {
    store.values[GatewayKeys.storeKey] = 'sk-eai-revoked';
    final keys = GatewayKeys(store: store, mint: mint);
    await keys.key();
    expect(await keys.renewAfterRefusal(), 'sk-eai-new-1');
    expect(await keys.renewAfterRefusal(), 'sk-eai-new-1');
    expect(await keys.renewAfterRefusal(recent: Duration.zero), 'sk-eai-new-2');
  });

  test('clear forgets the key, so the next account mints its own', () async {
    final prefs = Preferences.inMemory({GatewayKeys.legacyKey: 'sk-eai-old'});
    final keys = GatewayKeys(store: store, mint: mint, legacy: prefs);
    await keys.key();
    await keys.clear();
    expect(store.values, isEmpty);
    expect(await keys.key(), 'sk-eai-new-1');
  });

  test('agent-server auth errors are recognized', () {
    expect(isGatewayAuthFailure('litellm.AuthenticationError: OpenAIException - invalid API key'), isTrue);
    expect(isGatewayAuthFailure('Error code: 401'), isTrue);
    expect(isGatewayAuthFailure('RateLimitError: slow down'), isFalse);
    expect(isGatewayAuthFailure('wrote 4010 lines'), isFalse);
  });

  test('the side model retries once with a new key after a 401', () async {
    final auths = <String>[];
    final client = MockClient((req) async {
      final auth = req.headers['Authorization']!;
      auths.add(auth);
      if (auth == 'Bearer sk-eai-old') return http.Response('{"error":"invalid API key"}', 401);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'ok'},
            },
          ],
        }),
        200,
      );
    });
    final ask = gatewaySummarizer(
      baseUrl: 'http://127.0.0.1:1/v1',
      apiKey: 'sk-eai-old',
      sessionTag: 's',
      client: client,
      onUnauthorized: (stale) async => stale == 'sk-eai-old' ? 'sk-eai-new' : fail('stale $stale'),
    );
    expect(await ask(const []), 'ok');
    expect(await ask(const []), 'ok');
    expect(auths, ['Bearer sk-eai-old', 'Bearer sk-eai-new', 'Bearer sk-eai-new']);

    final noRetry = gatewaySummarizer(
      baseUrl: 'http://127.0.0.1:1/v1',
      apiKey: 'sk-eai-old',
      sessionTag: 's',
      client: client,
    );
    await expectLater(noRetry(const []), throwsA(isA<HarnessError>().having((e) => e.status, 'status', 401)));
  });
}
