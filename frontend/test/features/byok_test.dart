import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/billing/billing_providers.dart';
import 'package:every_ai/features/billing/ui/billing_screen.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/usage/ui/usage_meter.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:every_ai/features/settings/byok_keys.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/settings/domain/byok_providers.dart';
import 'package:every_ai/features/settings/domain/key_check.dart';
import 'package:every_ai/features/settings/ui/api_keys_section.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Billing extends BillingController {
  @override
  Future<BillingSummary> build() async => BillingSummary.fromJson({
    'plan': {'id': 'free', 'name': 'Free', 'price_cents': 0, 'included_micros': 0},
    'period_end': 1795000000,
    'included_micros': 0,
    'used_micros': 0,
    'wallet_micros': 0,
  });
}

Widget _app(List<Override> overrides, Widget child, {Preferences? prefs}) => ProviderScope(
  overrides: [preferencesProvider.overrideWithValue(prefs ?? Preferences.inMemory()), ...overrides],
  child: m.MaterialApp(
    builder: (context, c) =>
        EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
    home: m.Material(child: child),
  ),
);

void main() {
  test('only providers with a proven path are offered', () {
    expect(byokProviders.map((p) => p.id), ['openrouter', 'anthropic']);
    for (final p in byokProviders) {
      expect(p.logo, startsWith('assets/'));
      expect(p.header, startsWith('X-Provider-Key-'));
    }
  });

  test('keys go to the keychain under byok.<id>', () async {
    final store = _MemoryStore()..values['byok.openrouter'] = 'sk-or-v1-abcdefgh1234';
    final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(store)]);
    addTearDown(c.dispose);
    expect(await c.read(byokKeysProvider.future), {'openrouter': 'sk-or-v1-abcdefgh1234'});
    await c.read(byokKeysProvider.notifier).save('anthropic', '  sk-ant-xyz9876 ');
    expect(store.values['byok.anthropic'], 'sk-ant-xyz9876');
    await c.read(byokKeysProvider.notifier).remove('openrouter');
    expect(store.values.containsKey('byok.openrouter'), isFalse);
    expect(c.read(byokKeysProvider).value, {'anthropic': 'sk-ant-xyz9876'});
    await c.read(byokKeysProvider.notifier).save('anthropic', '');
    expect(store.values, isEmpty);
    expect(ByokKeys.lastFour('sk-ant-xyz9876'), '9876');
  });

  group('ModelBilling', () {
    const claude = ModelId('anthropic/claude-haiku-5.5');
    const gpt = ModelId('openai/gpt-6.1-sol');
    const both = ModelBilling(keys: {'openrouter': 'sk-or-v1-k', 'anthropic': 'sk-ant-k'});

    test('without keys everything bills to credits and sends no key', () {
      expect(ModelBilling.empty.billersFor(claude), [Biller.everyai]);
      expect(ModelBilling.empty.headersFor(claude), isEmpty);
    });

    test('an Anthropic key covers Claude only; an OpenRouter key covers everything', () {
      expect(both.billersFor(claude).map((b) => b.id), ['everyai', 'openrouter', 'anthropic']);
      expect(both.billersFor(gpt).map((b) => b.id), ['everyai', 'openrouter']);
      const ant = ModelBilling(keys: {'anthropic': 'sk-ant-k'});
      expect(ant.billersFor(gpt), [Biller.everyai]);
    });

    test('by default the most specific key pays, and only its header goes out', () {
      expect(both.billerFor(claude).id, 'anthropic');
      expect(both.headersFor(claude), {'X-Provider-Key-Anthropic': 'sk-ant-k'});
      expect(both.headersFor(gpt), {'X-Provider-Key-OpenRouter': 'sk-or-v1-k'});
    });

    test('a pick holds while its key exists, and falls back once it is removed', () {
      final picked = ModelBilling(keys: both.keys, choices: {claude.value: 'openrouter', gpt.value: 'everyai'});
      expect(picked.headersFor(claude), {'X-Provider-Key-OpenRouter': 'sk-or-v1-k'});
      expect(picked.headersFor(gpt), isEmpty);
      final gone = ModelBilling(keys: const {'anthropic': 'sk-ant-k'}, choices: picked.choices);
      expect(gone.billerFor(claude).id, 'anthropic');
    });
  });

  test('spend counts what the key paid', () {
    final t = UsageTotals.fromJson({'charged_micros': 100, 'byok_cost_micros': 2500});
    expect(t.spentMicros, 2600);
    expect((t + t).ownKeyMicros, 5000);
  });

  testWidgets('the meter keeps counting after a switch to an own key, and splits the cost', (tester) async {
    final totals = const UsageTotals()
        .addCall(prompt: 1000, completion: 100, charged: 1500000)
        .addCall(prompt: 1000, completion: 100, ownKey: 2500000);
    expect(totals.spentMicros, 4000000);
    await tester.pumpWidget(_app(const [], Center(child: UsageMeter(totals: totals, contextWindow: 0))));
    expect(find.textContaining(formatMicros(4000000)), findsOneWidget);
    await tester.pumpWidget(_app(const [], UsageBreakdown(totals: totals, contextWindow: 0)));
    expect(find.text('On your own key'), findsOneWidget);
    expect(find.text(formatMicros(2500000)), findsOneWidget);
  });

  testWidgets('a card adds a key behind a masked field, checks it and removes it', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _MemoryStore();
    final checked = <String>[];
    await tester.pumpWidget(
      _app([
        secretStoreProvider.overrideWithValue(store),
        keyCheckProvider.overrideWithValue((p, key) async {
          checked.add(key);
          return (valid: false, message: '${p.name} rejected this key.');
        }),
      ], const ApiKeysSection()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bring your own key'), findsOneWidget);
    expect(find.text('Not connected'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('byok.openrouter.add')));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(m.AlertDialog), matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(field).obscureText, isTrue);
    await tester.enterText(field, 'sk-or-v1-secret_ABCD');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.values['byok.openrouter'], 'sk-or-v1-secret_ABCD');
    expect(checked, ['sk-or-v1-secret_ABCD']);
    expect(find.text('•••• ABCD · rejected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('byok.openrouter.more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(store.values, isEmpty);
    expect(find.text('Not connected'), findsNWidgets(2));
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('the Ultra spend cap is editable and kept', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = Preferences.inMemory();
    await tester.pumpWidget(
      _app([secretStoreProvider.overrideWithValue(_MemoryStore())], const ApiKeysSection(), prefs: prefs),
    );
    await tester.pumpAndSettle();
    expect(find.text('\$25.00'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('byok.ultra-cap.edit')));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(m.AlertDialog), matching: find.byType(EditableText));
    await tester.enterText(field, '40');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('\$40.00'), findsOneWidget);
    expect(prefs['byok.ultra_cap_usd'], '40.0');
  });

  testWidgets('Billing shows the static plans; Choose says it is coming', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app([billingProvider.overrideWith(_Billing.new)], const BillingBody()));
    await tester.pumpAndSettle();
    expect(find.text('Requires an account.'), findsOneWidget);
    expect(find.text('~\$20/mo'), findsOneWidget);
    expect(find.text('~\$100/mo'), findsOneWidget);
    expect(find.text('Pay as you go'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plans.choose.super')));
    await tester.pump();
    expect(find.text('Super is coming soon.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });
}
