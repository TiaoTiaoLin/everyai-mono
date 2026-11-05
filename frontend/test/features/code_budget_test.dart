import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

/// A ledger reading the test sets.
final _spent = <String, int>{};

Future<T> _until<T>(T Function() read, bool Function(T) cond) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

CodeSessionInfo _info(String id, {String? parent, bool ownTag = false, String dir = '/p'}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: id,
  conversationId: 'c-$id',
  model: 'm',
  mode: AgentMode.ask,
  workingDir: dir,
  createdAt: DateTime(2026),
  parentId: parent,
  ownTag: ownTag,
);

void main() {
  group('billing tags and processes', () {
    test('subagents bill to their parent, Ultra children to themselves', () {
      expect(_info('a').billingTag, 'a');
      expect(_info('b', parent: 'a').billingTag, 'a');
      expect(_info('c', parent: 'a', ownTag: true).billingTag, 'c');
      final back = CodeSessionInfo.fromJson(_info('c', parent: 'a', ownTag: true).toJson());
      expect(back.ownTag, isTrue);
      expect(back.bypassChecks, isFalse);
      expect(CodeSessionInfo.fromJson(back.copyWith(bypassChecks: true).toJson()).bypassChecks, isTrue);
      // Saved before the flag: an Ultra call id still marks it.
      final legacy = {..._info('d', parent: 'a').toJson(), 'parent_call_id': 'ultra-r1-a.s-1'};
      expect(CodeSessionInfo.fromJson(legacy).billingTag, 'd');
    });

    test('Ultra children end their own processes; other subagents leave it to the parent', () {
      final parent = _info('a', dir: '/wt/a');
      expect(killsOwnProcesses(parent), isTrue);
      expect(killsOwnProcesses(_info('b', parent: 'a')), isFalse);
      final step = _info('c', parent: 'a', ownTag: true, dir: '/ultra/r1/a.s');
      expect(killsOwnProcesses(step), isTrue);
      expect(ownsWorkingDir(step, parent: parent), isTrue);
      expect(
        ownsWorkingDir(
          _info('d', parent: 'a', ownTag: true, dir: '/wt/a'),
          parent: parent,
        ),
        isFalse,
      );
      expect(killsOwnProcesses(_info('e', dir: 'demo://counter-app')), isFalse);
    });

    test('a budget counts children billed under their own ids', () {
      final sessions = [
        _info('a'),
        _info('b', parent: 'a'),
        _info('c', parent: 'a', ownTag: true),
        _info('x', parent: 'z', ownTag: true),
      ];
      final usage = {'a': 100, 'b': 999, 'c': 50, 'x': 7};
      expect(budgetSpentMicros('a', sessions: sessions, usage: (id) => usage[id]), 150);
    });
  });

  group('budget', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      _spent.clear();
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([
        const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
      ]);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          harnessProvider.overrideWithValue(FakeHarness(step: Duration.zero)),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
          codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals(chargedMicros: _spent[n.sessionId] ?? 0)),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('a spent budget refuses new messages until it is raised', () async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'Add decrement',
            model: 'anthropic/claude-haiku-5.5',
            mode: AgentMode.ask,
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await _until(() => container.read(codeSessionProvider(info.id)).transcript.openQuestion, (q) => q != null);
      final controller = container.read(codeSessionProvider(info.id).notifier);
      int turns() => container.read(codeSessionProvider(info.id)).transcript.items.whereType<UserTurn>().length;

      _spent[info.id] = 2000000;
      container.invalidate(codeUsageProvider(info.id));
      await container.read(codeUsageProvider(info.id).future);
      container.read(codeSettingsProvider.notifier).setBudget(info.id, 1);
      final before = turns();
      await controller.send('Carry on');
      expect(turns(), before);
      expect(container.read(codeSessionProvider(info.id)).error, contains('budget'));

      container.read(codeSettingsProvider.notifier).setBudget(info.id, 5);
      expect(container.read(codeSessionProvider(info.id)).error, isNull);
      await controller.send('Carry on');
      await _until(turns, (n) => n > before);
    });
  });
}
