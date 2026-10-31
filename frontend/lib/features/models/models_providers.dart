import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/net/api_client.dart';
import '../../core/preferences.dart';
import '../../core/providers.dart';
import 'domain/model_catalog.dart';

/// The model shop: the backend's catalog (`GET /v1/models`). Starts from the
/// last cached copy (or the built-in featured models on first launch) so it is
/// always available synchronously, then refreshes when older than an hour.
final modelCatalogProvider = NotifierProvider<CatalogController, ModelCatalog>(CatalogController.new);

class CatalogController extends Notifier<ModelCatalog> {
  static const _cacheKey = 'catalog.json';
  static const _fetchedKey = 'catalog.fetched_at';
  static const _maxAge = Duration(hours: 1);

  Preferences get _prefs => ref.read(preferencesProvider);
  ApiClient get _api => ref.read(apiClientProvider);

  /// Whether the last refresh failed (the shop shows a retry banner).
  bool lastRefreshFailed = false;

  @override
  ModelCatalog build() {
    final cached = _prefs[_cacheKey];
    final catalog = (cached == null ? null : _parse(cached)) ?? builtInCatalog;
    final fetched = DateTime.tryParse(_prefs[_fetchedKey] ?? '');
    if (fetched == null || DateTime.now().difference(fetched) > _maxAge || cached == null) {
      Future.microtask(refresh);
    }
    return catalog;
  }

  Future<void> refresh() async {
    try {
      final json = await _api.getJson('v1/models');
      final catalog = _fromJson(json);
      if (catalog == null || !ref.mounted) return;
      lastRefreshFailed = false;
      state = catalog;
      _prefs[_cacheKey] = jsonEncode(json);
      _prefs[_fetchedKey] = DateTime.now().toIso8601String();
    } on Object {
      lastRefreshFailed = true; // keep what we have
    }
  }

  static ModelCatalog? _parse(String raw) {
    try {
      return _fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  static ModelCatalog? _fromJson(Object? json) {
    if (json case {'data': final List<Object?> data}) {
      final specs = data.map(ModelSpec.fromJson).nonNulls.toList();
      if (specs.isEmpty) return null;
      return ModelCatalog(specs, defaultModel: defaultModelId);
    }
    return null;
  }
}

/// Model new chats start with. Persisted.
final defaultModelProvider = NotifierProvider<DefaultModel, ModelSpec>(DefaultModel.new);

final class DefaultModel extends Notifier<ModelSpec> {
  static const _key = 'default_model';

  @override
  ModelSpec build() {
    final catalog = ref.watch(modelCatalogProvider);
    final saved = ref.watch(preferencesProvider)[_key];
    return (saved == null ? null : catalog[ModelId(saved)]) ?? catalog.defaultModel;
  }

  void set(ModelSpec model) {
    ref.read(preferencesProvider)[_key] = model.id.value;
    state = model;
  }
}

/// "My models": the user's list, shown in the composer's picker, in order.
/// Persisted locally; first run starts with the featured models.
final libraryProvider = AsyncNotifierProvider<Library, List<ModelSpec>>(Library.new);

final class Library extends AsyncNotifier<List<ModelSpec>> {
  AppDatabase get _db => ref.read(databaseProvider);

  @override
  Future<List<ModelSpec>> build() async {
    final catalog = ref.watch(modelCatalogProvider);
    final rows = await (_db.select(_db.libraryModels)..orderBy([(r) => OrderingTerm.asc(r.position)])).get();
    final prefs = ref.read(preferencesProvider);
    final addAuto = prefs[_autoAddedKey] == null;
    prefs[_autoAddedKey] = '1';
    if (rows.isEmpty) return catalog.all.where((s) => s.featured).toList(growable: false);
    final seen = <ModelId>{};
    final models = [
      for (final r in rows)
        if (catalog.resolve(ModelId(r.modelId)) case final s when seen.add(s.id)) s,
    ];
    // Libraries from before Auto get it once, at the top; removing it later sticks.
    if (addAuto && !seen.contains(autoModelId)) {
      final withAuto = [catalog.resolve(autoModelId), ...models];
      await _write(withAuto);
      return withAuto;
    }
    return models;
  }

  static const _autoAddedKey = 'models.auto_added';

  bool contains(ModelId id) => state.value?.any((s) => s.id == id) ?? false;

  Future<void> toggle(ModelSpec model) async {
    final current = [...?state.value];
    final index = current.indexWhere((s) => s.id == model.id);
    if (index == -1) {
      current.add(model);
    } else {
      current.removeAt(index);
    }
    await _save(current);
  }

  Future<void> reorder(int from, int to) async {
    final current = [...?state.value];
    if (from < 0 || from >= current.length) return;
    final item = current.removeAt(from);
    current.insert(to.clamp(0, current.length), item);
    await _save(current);
  }

  Future<void> _save(List<ModelSpec> models) async {
    state = AsyncData(List.unmodifiable(models));
    await _write(models);
  }

  Future<void> _write(List<ModelSpec> models) async {
    await _db.transaction(() async {
      await _db.delete(_db.libraryModels).go();
      for (final (i, s) in models.indexed) {
        await _db.into(_db.libraryModels).insert(LibraryModelsCompanion.insert(modelId: s.id.value, position: i));
      }
    });
  }
}
