import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/models/ui/models_screen.dart';
import 'package:every_ai/features/settings/byok_keys.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

final class _Store implements SecretStore {
  _Store(this.values);
  final Map<String, String> values;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Nothing featured but Auto, so My models starts with Auto alone.
class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => ModelCatalog(const [
    ModelSpec(
      id: ModelId('anthropic/claude-haiku-5.5'),
      provider: ModelProvider.anthropic,
      name: 'Claude Haiku 5.5',
      blurb: 'Fast',
    ),
    ModelSpec(id: ModelId('openai/gpt-6.1-sol'), provider: ModelProvider.openai, name: 'GPT-6.1 Sol', blurb: 'Smart'),
  ], defaultModel: const ModelId('anthropic/claude-haiku-5.5'));
}

void main() {
  Future<ProviderContainer> pump(WidgetTester tester, Map<String, String> keys) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(Preferences.inMemory()),
        secretStoreProvider.overrideWithValue(_Store({for (final e in keys.entries) 'byok.${e.key}': e.value})),
        modelCatalogProvider.overrideWith(_Catalog.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: m.MaterialApp(
          builder: (context, c) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.dark), child: c!),
          home: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: const ModelsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  const haiku = 'anthropic/claude-haiku-5.5';

  testWidgets('with one account, Add just adds', (tester) async {
    await pump(tester, const {});
    expect(find.byKey(const ValueKey('shop.add.$haiku')), findsNothing);
    expect(find.text('On your keys'), findsNothing);
  });

  testWidgets('with several accounts, Add asks who pays and remembers it', (tester) async {
    final c = await pump(tester, const {'openrouter': 'sk-or-v1-k', 'anthropic': 'sk-ant-k'});
    expect(find.text('On your keys'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shop.add.$haiku')));
    await tester.pumpAndSettle();
    expect(find.text('Bill to EveryAI credits'), findsOneWidget);
    expect(find.text('Bill to Your Anthropic key'), findsOneWidget);
    await tester.tap(find.text('Bill to Your OpenRouter key'));
    await tester.pumpAndSettle();

    expect(c.read(modelBillersProvider), {haiku: 'openrouter'});
    expect(c.read(libraryProvider).value!.map((s) => s.id.value), [autoModelId.value, haiku]);
    expect(c.read(modelBillingProvider).headersFor(const ModelId(haiku)), {'X-Provider-Key-OpenRouter': 'sk-or-v1-k'});
    // Haiku by the pick; GPT and Auto because, unpicked, a key that covers a model pays for it.
    expect(find.textContaining('Bills to your OpenRouter key'), findsNWidgets(3));
  });
}
