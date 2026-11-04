import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/ui/transcript/lead_offer_card.dart';
import 'package:every_ai/features/code/ui/transcript/transcript_items.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

Widget _host(Widget child) => m.MaterialApp(
  home: EveryThemeScope(
    theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
    child: m.Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('the offer lists the ready harnesses with their models, and Wait', (tester) async {
    final picked = <String>[];
    var waited = false;
    await tester.pumpWidget(
      _host(
        LeadOfferCard(
          lead: 'Claude Code',
          limit: UsageLimit(message: 'limit', resetsAt: DateTime(2026, 11, 5, 15)),
          now: DateTime(2026, 11, 5, 9),
          choices: const [
            (id: 'codex', label: 'Codex', subtitle: 'gpt-6.1 · on your plan'),
            (id: 'everyai', label: 'EveryAI', subtitle: 'Sonnet 5.5 · credits'),
          ],
          onSwitch: picked.add,
          onWait: () => waited = true,
        ),
      ),
    );
    expect(find.text("You're out of Claude Code usage (resets at 15:00)."), findsOneWidget);
    expect(find.text('Sonnet 5.5 · credits'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lead-offer.codex')));
    expect(picked, ['codex']);
    await tester.tap(find.byKey(const ValueKey('lead-offer.wait')));
    expect(waited, isTrue);
  });

  test('a reset on another day names the day', () {
    expect(resetText(DateTime(2026, 11, 6, 3, 5), DateTime(2026, 11, 5, 22)), 'Nov 6, 03:05');
  });

  testWidgets('a notice with detail opens to show it', (tester) async {
    await tester.pumpWidget(
      _host(const NoticeView(item: NoticeItem('h', 'Handoff to Codex', detail: '<everyai-handoff>facts'))),
    );
    expect(find.textContaining('facts'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('notice.detail')));
    await tester.pump();
    expect(find.textContaining('facts'), findsOneWidget);
  });
}
