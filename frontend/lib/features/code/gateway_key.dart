import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/preferences.dart';
import '../../core/providers.dart';

/// Where the gateway key is kept between launches.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The OS keychain/keystore, as for the refresh token (see `TokenStore`).
final class KeychainSecretStore implements SecretStore {
  const KeychainSecretStore();

  // Unsigned macOS debug builds can't use the data-protection keychain.
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: !kDebugMode));

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// The user's `sk-eai-` key for the backend's OpenAI-compatible gateway; the
/// harness and the side jobs send their model calls there.
///
/// Kept in the keychain. Older builds kept it in Preferences
/// (`code.gateway_key`); the first read moves it. A key the gateway refuses
/// (revoked, another account, a reset dev database) is replaced with
/// [remint].
final class GatewayKeys {
  GatewayKeys({required this._store, required this._mint, this._legacy});

  static const storeKey = 'everyai.code.gateway_key';
  static const legacyKey = 'code.gateway_key';

  final SecretStore _store;
  final Future<String> Function() _mint;
  final Preferences? _legacy;

  String? _key;
  Future<String>? _loading;

  /// The current key: from memory, the keychain, the old Preferences entry,
  /// or freshly minted. Concurrent callers share one lookup.
  Future<String> key() async {
    if (_key case final k?) return k;
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  /// A new key, after the gateway refused [stale]. If someone already
  /// replaced [stale], that key is returned instead of minting another.
  Future<String> remint(String stale) async {
    if (_loading case final loading?) await loading.catchError((Object _) => '');
    if (_key case final k? when k != stale) return k;
    return _loading ??= _fresh().whenComplete(() => _loading = null);
  }

  /// A new key after the harness reported a refusal, which doesn't say
  /// which key it sent. A key minted within [recent] is taken as the fix
  /// another session already made.
  Future<String> renewAfterRefusal({Duration recent = const Duration(minutes: 1)}) async {
    if (_loading case final loading?) await loading.catchError((Object _) => '');
    if (_mintedAt case final at? when _key != null && DateTime.now().difference(at) < recent) return _key!;
    return remint(_key ?? '');
  }

  DateTime? _mintedAt;

  /// Forgets the key (sign-out); the next [key] mints one for the new user.
  Future<void> clear() async {
    _key = null;
    _legacy?[legacyKey] = null;
    await _store.delete(storeKey);
  }

  Future<String> _load() async {
    String? stored;
    try {
      stored = await _store.read(storeKey);
    } on Object {
      stored = null;
    }
    if (stored != null && stored.isNotEmpty) {
      _legacy?[legacyKey] = null;
      return _key = stored;
    }
    if (_legacy?[legacyKey] case final old? when old.isNotEmpty) {
      await _save(old);
      _legacy?[legacyKey] = null;
      return _key = old;
    }
    return _fresh();
  }

  Future<String> _fresh() async {
    final key = await _mint();
    _mintedAt = DateTime.now();
    await _save(key);
    return _key = key;
  }

  Future<void> _save(String key) async {
    try {
      await _store.write(storeKey, key);
    } on Object {
      // Without a keychain the key lasts this launch; the next one mints again.
    }
  }
}

/// The store [gatewayKeysProvider] uses; tests override it.
final secretStoreProvider = Provider<SecretStore>((ref) => const KeychainSecretStore());

final gatewayKeysProvider = Provider<GatewayKeys>((ref) {
  return GatewayKeys(
    store: ref.watch(secretStoreProvider),
    legacy: ref.watch(preferencesProvider),
    mint: () async {
      // Dev builds skip sign-in; the backend's DEV_AUTH treats them as its dev user.
      final authenticated = !ref.read(appConfigProvider).devSkipAuth;
      final res = await ref.read(apiClientProvider).postJson('v1/keys', {
        'name': 'EveryAI Code',
      }, authenticated: authenticated);
      return res['key']! as String;
    },
  );
});

/// Whether a harness error means the gateway refused the key: the gateway's
/// own text is "invalid API key" (LiteLLM clients say `AuthenticationError`).
bool isGatewayAuthFailure(String message) =>
    RegExp(r'AuthenticationError|invalid API key|\b401\b', caseSensitive: false).hasMatch(message);

/// A new gateway key after the gateway refused [stale]; for `onUnauthorized`.
Future<String> remintGatewayKey(Ref ref, String stale) => ref.read(gatewayKeysProvider).remint(stale);
