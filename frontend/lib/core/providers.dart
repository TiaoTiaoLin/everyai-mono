import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/data/token_store.dart';
import 'config/app_config.dart';
import 'db/app_database.dart';
import 'net/api_client.dart';
import 'net/http_client.dart';

/// App-wide singletons. Override these in tests (e.g. an in-memory database).

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnvironment());

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// One pooled client for the whole app (HTTP/2 and QUIC sessions get reused).
final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ApiClient(
    baseUrl: config.apiBaseUrl,
    client: createPlatformHttpClient(userAgent: 'EveryAI/0.1'),
    tokens: ref.watch(tokenStoreProvider),
    // A deployed backend may be starting (cold start, restart): requests wait for it.
    waitForServer: true,
  );
  ref.onDispose(client.close);
  return client;
});

/// The backend's [ServerStatus] while it's not plainly online (the shell's "waking up" banner).
final serverStatusProvider = StreamProvider<ServerStatus>((ref) {
  final client = ref.watch(apiClientProvider);
  // Start waking it now, not at the first request.
  unawaited(client.awaitOnline().catchError((Object _) {}));
  return client.status;
});
