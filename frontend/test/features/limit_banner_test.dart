import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart' show codeUsageProvider;
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/limit_providers.dart';
import 'package:every_ai/features/code/ui/limit_banner.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

final _now = DateTime.utc(2026, 11, 4, 12);

/// A five-hour window [used] up, which resets in [left] minutes.
PlanLimits _plan(double used, {int? left = 270, int? minutes = 300, bool warning = false, String name = 'five_hour'}) =>
    PlanLimits.of(
      id: 'l',
      windows: [
        PlanWindow(
          name: name,
          used: used,
          resetsAt: left == null ? null : _now.add(Duration(minutes: left)),
          minutes: minutes,
        ),
      ],
      warning: warning,
    );

void main() {
  group('limitBannerOf', () {
    test('nothing reported: no banner', () {
      expect(limitBannerOf(now: _now), isNull);
      expect(
        limitBannerOf(
          plan: PlanLimits.of(id: 'e', windows: const []),
          now: _now,
        ),
        isNull,
      );
    });

    test('a quarter used a tenth into the window is on pace to run out early', () {
      final b = limitBannerOf(plan: _plan(0.26), now: _now)!;
      expect(b.text, startsWith('On pace to hit your limit early · 26% used · resets '));
      expect(b.key, 'plan:five_hour:${_now.add(const Duration(minutes: 270)).millisecondsSinceEpoch ~/ 1000}');
      expect(b.danger, isFalse);
    });

    test('used no faster than time goes by, and no warning: no banner', () {
      expect(limitBannerOf(plan: _plan(0.26, left: 150), now: _now), isNull);
      // Under a quarter, even when fast.
      expect(limitBannerOf(plan: _plan(0.2, left: 299), now: _now), isNull);
    });

    test("the harness's own warning, without a window length or reset", () {
      final b = limitBannerOf(plan: _plan(0.82, left: null, minutes: null, warning: true), now: _now)!;
      expect(b.text, 'Close to your limit · 82% used');
    });

    test('the fullest window counts', () {
      final plan = PlanLimits.of(
        id: 'two',
        windows: [
          PlanWindow(name: 'a', used: 0.1, resetsAt: _now.add(const Duration(minutes: 10)), minutes: 300),
          PlanWindow(name: 'b', used: 0.9, resetsAt: _now.add(const Duration(minutes: 200)), minutes: 300),
        ],
      );
      expect(limitBannerOf(plan: plan, now: _now)!.key, startsWith('plan:b:'));
    });

    test('the session cap from 80%, danger once reached; a plan banner comes first', () {
      final near = limitBannerOf(chargedMicros: 4250000, budgetUsd: 5, now: _now)!;
      expect((near.key, near.danger), ('budget:80', false));
      expect(near.text, contains('85% of your'));
      final reached = limitBannerOf(chargedMicros: 5000000, budgetUsd: 5, now: _now)!;
      expect((reached.key, reached.danger), ('budget:100', true));
      expect(limitBannerOf(chargedMicros: 3000000, budgetUsd: 5, now: _now), isNull);
      expect(
        limitBannerOf(plan: _plan(0.26), chargedMicros: 5000000, budgetUsd: 5, now: _now)!.key,
        startsWith('plan:'),
      );
    });
  });

  group('LimitBanner', () {
    late Preferences prefs;
    setUp(() => prefs = Preferences.inMemory());

    Future<ProviderContainer> pump(WidgetTester tester, {UsageTotals usage = UsageTotals.zero}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            codeUsageProvider.overrideWithBuild((ref, n) async => usage),
          ],
          child: m.MaterialApp(
            home: m.Material(
              child: EveryThemeScope(
                theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
                child: LimitBanner(sessionId: 's1', now: () => _now),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return ProviderScope.containerOf(tester.element(find.byType(LimitBanner)));
    }

    testWidgets('shows only what was reported; × hides it until a new window', (tester) async {
      final c = await pump(tester);
      expect(find.byKey(const ValueKey('limit-banner')), findsNothing);

      c.read(codePlanLimitsProvider('s1').notifier).set(_plan(0.26));
      await tester.pump();
      expect(find.textContaining('On pace to hit your limit early'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('limit-banner.dismiss')));
      await tester.pump();
      expect(find.byKey(const ValueKey('limit-banner')), findsNothing);
      expect(prefs['${codeLimitBannerPrefix}s1'], startsWith('plan:five_hour:'));

      // Still closed when built again, and for a later report of the same window.
      await pump(tester);
      c.read(codePlanLimitsProvider('s1').notifier).set(_plan(0.3));
      await tester.pump();
      expect(find.byKey(const ValueKey('limit-banner')), findsNothing);

      // A new window (another reset) shows it again.
      c.read(codePlanLimitsProvider('s1').notifier).set(_plan(0.3, left: 260));
      await tester.pump();
      expect(find.byKey(const ValueKey('limit-banner')), findsOneWidget);
    });

    testWidgets('the session cap, from what the session spent', (tester) async {
      final c = await pump(tester, usage: UsageTotals.zero.addCall(prompt: 1, completion: 1, charged: 4500000));
      c.read(codeSettingsProvider.notifier).setBudget('s1', 5);
      await tester.pump();
      expect(find.textContaining('90% of your'), findsOneWidget);
    });
  });
}
