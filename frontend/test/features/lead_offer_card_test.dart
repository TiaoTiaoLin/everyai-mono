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
  testWidgets('the picker lists the harnesses, greys the blocked ones, and can make the pick the default', (
    tester,
  ) async {
    final picked = <(String, bool)>[];
    var waited = false;
    await tester.pumpWidget(
      _host(
        LeadOfferCard(
          lead: 'Claude Code',
          limit: UsageLimit(message: 'You hit your 5-hour limit.', resetsAt: DateTime(2026, 11, 5, 15)),
          now: DateTime(2026, 11, 5, 9),
          problem: 'Codex: Not signed in',
          choices: const [
            (id: 'codex', label: 'Codex', subtitle: 'gpt-6.1 · on your plan', blocked: null),
            (id: 'everyai', label: 'EveryAI', subtitle: 'Sonnet 5.5 · credits', blocked: null),
            (id: 'gemini', label: 'Gemini CLI', subtitle: 'Default model · on your plan', blocked: 'Not signed in'),
          ],
          onSwitch: (id, makeDefault) => picked.add((id, makeDefault)),
          onWait: () => waited = true,
        ),
      ),
    );
    expect(find.text('Your Claude Code limit ran out, switch to:'), findsOneWidget);
    expect(find.text('You hit your 5-hour limit.'), findsOneWidget);
    expect(find.text('Codex: Not signed in'), findsOneWidget);
    expect(find.text('Sonnet 5.5 · credits'), findsOneWidget);
    expect(find.text('Wait until 15:00'), findsOneWidget);
    // Blocked: its fix shows, and a tap does nothing.
    expect(find.text('Not signed in'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lead-offer.gemini')));
    expect(picked, isEmpty);
    await tester.tap(find.byKey(const ValueKey('lead-offer.codex')));
    await tester.tap(find.byKey(const ValueKey('lead-offer.default')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lead-offer.everyai')));
    expect(picked, [('codex', false), ('everyai', true)]);
    await tester.tap(find.byKey(const ValueKey('lead-offer.wait')));
    expect(waited, isTrue);
  });

  testWidgets('without a reset time it is Wait; reopened with Change it is Keep', (tester) async {
    Widget card({bool change = false}) => _host(
      LeadOfferCard(
        key: ValueKey(change),
        lead: 'Claude Code',
        current: 'Codex',
        change: change,
        limit: const UsageLimit(message: ''),
        choices: const [],
        onSwitch: (_, _) {},
        onWait: () {},
      ),
    );
    await tester.pumpWidget(card());
    expect(find.text('Wait'), findsOneWidget);
    expect(find.text('No other harness is ready. Connect one in Settings → Code, or wait.'), findsOneWidget);
    expect(find.byKey(const ValueKey('lead-offer.default')), findsNothing);
    await tester.pumpWidget(card(change: true));
    expect(find.text('Keep Codex'), findsOneWidget);
  });

  testWidgets('an automatic handoff notice offers Change', (tester) async {
    var changed = 0;
    await tester.pumpWidget(
      _host(
        NoticeView(
          item: const NoticeItem('h', 'Your Alpha limit ran out; continuing on Beta', handedOffFrom: 'alpha'),
          onChange: () => changed++,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('notice.change')));
    expect(changed, 1);
  });

  test('a reset on another day names the day', () {
    expect(resetText(DateTime(2026, 11, 6, 3, 5), DateTime(2026, 11, 5, 22)), 'Nov 6, 03:05');
    expect(resetText(DateTime(2026, 11, 5, 23, 5), DateTime(2026, 11, 5, 22)), '23:05');
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
