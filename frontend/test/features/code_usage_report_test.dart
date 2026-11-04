import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('a usage report keeps its kind through the wire, so the mirror carries it', () {
    final r = UsageReport.of(
      id: 'u1',
      input: 1200,
      output: 80,
      cached: 1000,
      contextTokens: 900,
      costMicros: 4200,
      onPlan: true,
    );
    final back = HarnessEvent.decodeFrame(jsonEncode(r.raw));
    expect(back, isA<UsageReport>());
    back as UsageReport;
    expect(
      (back.id, back.input, back.output, back.cached, back.contextTokens, back.costMicros, back.onPlan),
      ('u1', 1200, 80, 1000, 900, 4200, true),
    );
    final noCost = HarnessEvent.decode(UsageReport.of(id: 'u2', input: 1, output: 2).raw) as UsageReport;
    expect((noCost.costMicros, noCost.onPlan), (null, false));
  });

  test('plan cost is shown apart and never counted as spending', () {
    const a = UsageTotals(chargedMicros: 10, ownKeyMicros: 5, planMicros: 700);
    expect(a.spentMicros, 15);
    expect(UsageTotals.fromJson(a.toJson()), a);
    expect((a + const UsageTotals(planMicros: 300)).planMicros, 1000);
    expect(a == const UsageTotals(chargedMicros: 10, ownKeyMicros: 5), isFalse);
    expect(UsageTotals.zero.addCall(prompt: 1, completion: 1, plan: 9).planMicros, 9);
    expect(const UsageTotals().toJson().containsKey('plan_cost_micros'), isFalse);
  });

  group('the session meter', () {
    late AppDatabase db;
    late ProviderContainer container;
    var backend = <String, Object?>{};

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs['code.sessions'] = jsonEncode([
        CodeSessionInfo(
          id: 's1',
          projectId: 'p1',
          title: 't',
          conversationId: 'c1',
          model: 'm',
          mode: AgentMode.ask,
          workingDir: '/p',
          createdAt: DateTime(2026),
        ).toJson(),
      ]);
      backend = {'calls': 2, 'prompt_tokens': 500, 'completion_tokens': 50, 'charged_micros': 300};
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          // Answers `GET v1/usage/session/:id` with the backend reading.
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: Uri.parse('http://test/'),
              client: MockClient((_) async => http.Response(jsonEncode(backend), 200)),
            ),
          ),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('with no reports it is the backend reading', () async {
      final u = await container.read(codeUsageProvider('s1').future);
      expect(u, UsageTotals.fromJson(backend));
    });

    test('reports add to it once each; plan cost apart, own-key cost toward the budget', () async {
      await container.read(codeUsageProvider('s1').future);
      final meter = container.read(codeUsageProvider('s1').notifier);
      meter
        ..report(UsageReport.of(id: 'u1', input: 1000, output: 100, cached: 800, costMicros: 2000, onPlan: true))
        ..report(UsageReport.of(id: 'u1', input: 1000, output: 100, cached: 800, costMicros: 2000, onPlan: true))
        ..report(UsageReport.of(id: 'u2', input: 1200, output: 40, contextTokens: 400, costMicros: 900));
      final u = container.read(codeUsageProvider('s1')).requireValue;
      expect((u.calls, u.promptTokens, u.completionTokens, u.cachedTokens), (4, 2700, 190, 800));
      expect((u.chargedMicros, u.ownKeyMicros, u.planMicros, u.spentMicros), (300, 900, 2000, 1200));
      expect(u.lastPromptTokens, 400);
    });

    test("a turn's summed input doesn't fill the context ring", () async {
      backend = {};
      await container.read(codeUsageProvider('s1').future);
      // Six calls at ~60K each, reported once for the turn.
      container.read(codeUsageProvider('s1').notifier).report(UsageReport.of(id: 't1', input: 360000, output: 900));
      final u = container.read(codeUsageProvider('s1')).requireValue;
      expect((u.promptTokens, u.contextTokens), (360000, 0));
      container
          .read(codeUsageProvider('s1').notifier)
          .report(UsageReport.of(id: 't2', input: 130000, output: 200, contextTokens: 65000));
      expect(container.read(codeUsageProvider('s1')).requireValue.contextTokens, 65000);
    });

    test('reported spend outlives a restart, even when the conversation changed', () async {
      await container.read(codeUsageProvider('s1').future);
      container
          .read(codeUsageProvider('s1').notifier)
          .report(UsageReport.of(id: 'u1', input: 1000, output: 100, costMicros: 5000));
      // A fresh container on the same prefs: the app restarted after a
      // compaction moved the session to a conversation that never replays u1.
      final prefs = container.read(preferencesProvider);
      final again = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: Uri.parse('http://test/'),
              client: MockClient((_) async => http.Response(jsonEncode(backend), 200)),
            ),
          ),
        ],
      );
      addTearDown(again.dispose);
      final u = await again.read(codeUsageProvider('s1').future);
      expect((u.ownKeyMicros, u.spentMicros), (5000, 5300));
      // Replayed history isn't counted twice.
      again
          .read(codeUsageProvider('s1').notifier)
          .report(UsageReport.of(id: 'u1', input: 1000, output: 100, costMicros: 5000));
      expect(again.read(codeUsageProvider('s1')).requireValue.ownKeyMicros, 5000);
      // Removing the session drops what it kept.
      again.read(codeSessionsProvider.notifier).remove('s1');
      expect(prefs.keysStartingWith(codeUsageReportsPrefix), isEmpty);
    });
  });
}
