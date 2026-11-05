import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/ui/adaptive.dart';
import 'package:every_ai/features/code/agent_models.dart';
import 'package:every_ai/features/code/domain/agent_menu.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/ui/agent_menu.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart' show HarnessTier;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

const _catalog = AgentCatalog(
  tiers: [
    AgentTier('writer', 'Writer', ''),
    AgentTier('everyday', 'Everyday', ''),
    AgentTier('engineer', 'Engineer', ''),
    AgentTier('orchestrator', 'Orchestrator', ''),
  ],
  models: [
    AgentChoice(model: 'anthropic/claude-haiku-5.5', effort: 'medium', tier: 'writer', label: 'Haiku 5.5 · medium'),
    AgentChoice(model: 'anthropic/claude-opus-5.5', effort: 'xhigh', tier: 'orchestrator', label: 'Opus 5.5 · xhigh'),
    AgentChoice(model: 'openai/gpt-6.1-sol', effort: 'high', tier: 'engineer', label: 'GPT-6.1 Sol · high'),
    AgentChoice(model: 'anthropic/claude-opus-5.5', effort: 'medium', tier: 'everyday', label: 'Opus 5.5 · medium'),
  ],
  fallback: AgentChoice(
    model: 'anthropic/claude-opus-5.5',
    effort: 'medium',
    tier: 'everyday',
    label: 'Opus 5.5 · medium',
  ),
);

Widget _host(Widget child, {DesignLanguage design = DesignLanguage.material}) => m.MaterialApp(
  home: EveryThemeScope(
    theme: EveryTheme.resolve(design, Brightness.light),
    child: m.Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('agentMenuGroups', () {
    test('groups by vendor in catalog order, with tiers as ordered hints', () {
      final groups = agentMenuGroups(_catalog);
      expect([for (final (v, _) in groups) v.slug], ['anthropic', 'openai']);
      final anthropic = groups.first.$2;
      expect([for (final m in anthropic) m.name], ['Haiku 5.5', 'Opus 5.5']);
      final opus = anthropic.last;
      expect(opus.tiers, ['Everyday', 'Orchestrator']);
      expect(opus.tierHint, 'Everyday · Orchestrator');
      expect(opus.efforts, ['xhigh', 'medium']);
      expect(opus.recommendedEffort, 'xhigh');
    });

    test('adds an uncurated current model under its vendor', () {
      final groups = agentMenuGroups(_catalog, current: 'qwen/qwen4-coder', nameOf: (_) => 'Qwen4 Coder');
      final (vendor, models) = groups.last;
      expect(vendor.slug, 'qwen');
      expect(models.single.name, 'Qwen4 Coder');
      expect(models.single.tierHint, '');
      expect(agentMenuGroups(_catalog, current: 'openai/gpt-6.1-sol').last.$2, hasLength(1));
    });
  });

  test('effortForModel keeps a tested effort and otherwise takes the recommended one', () {
    final opus = agentMenuGroups(_catalog).first.$2.last;
    expect(effortForModel(opus, 'medium'), 'medium');
    expect(effortForModel(opus, 'low'), 'xhigh');
    const uncurated = AgentMenuModel(model: 'x/y', name: 'y', vendor: ModelProvider.anthropic);
    expect(effortForModel(uncurated, 'low'), 'low');
  });

  test('labels', () {
    expect(agentMenuLabel('Opus 5.5', ''), 'Opus 5.5');
    expect(agentMenuLabel('Opus 5.5', 'xhigh'), 'Opus 5.5 · Extra high');
  });

  group('AgentCatalog choices', () {
    test('choiceFor returns the curated entry or an uncurated one named after the model', () {
      expect(_catalog.choiceFor('openai/gpt-6.1-sol', 'high').tier, 'engineer');
      final off = _catalog.choiceFor('anthropic/claude-opus-5.5', 'low');
      expect(off.label, 'Opus 5.5 · low');
      expect(off.key, 'anthropic/claude-opus-5.5@low');
      expect(_catalog.choiceFor('qwen/qwen4-coder', '').label, 'qwen4-coder');
    });

    test('fromKey reads back any saved model@effort', () {
      expect(_catalog.fromKey('anthropic/claude-haiku-5.5@max')?.effort, 'max');
      expect(_catalog.fromKey('openai/gpt-6.1-sol@')?.effort, '');
      expect(_catalog.fromKey('nonsense'), isNull);
      expect(_catalog.fromKey(null), isNull);
    });
  });

  testWidgets('the menu opens Model and Effort as submenus and reports picks', (tester) async {
    final picks = <String>[];
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 320,
          height: 700,
          child: AgentMenuPanel(
            groups: agentMenuGroups(_catalog),
            model: 'anthropic/claude-opus-5.5',
            effort: 'medium',
            onChanged: (model, effort) => picks.add('$model@$effort'),
            close: () {},
          ),
        ),
      ),
    );
    // Without leads to pick from there is no Harness row.
    expect(find.text('Harness'), findsNothing);
    // Without a pick handler there is no Workflow row or effort level.
    expect(find.text('Workflow'), findsNothing);
    expect(find.text('Effort level'), findsNothing);
    expect(find.text('Opus 5.5 · Everyday · Orchestrator'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-menu.model')));
    await tester.pump();
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Engineer'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-menu.model.openai/gpt-6.1-sol')));
    await tester.pump();
    // GPT-6.1 Sol isn't curated at medium: its recommended effort comes along.
    expect(picks, ['openai/gpt-6.1-sol@high']);
    expect(find.text('Effort'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-menu.effort')));
    await tester.pump();
    expect(find.textContaining('recommended'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-menu.effort.default')));
    await tester.pump();
    expect(picks.last, 'openai/gpt-6.1-sol@');

    expect(find.byKey(const ValueKey('agent-menu.harness')), findsNothing);
    expect(find.text('Model'), findsOneWidget);
  });

  testWidgets("efforts are disabled for a model that doesn't reason", (tester) async {
    final picks = <String>[];
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 320,
          height: 700,
          child: AgentMenuPanel(
            groups: agentMenuGroups(_catalog),
            model: 'anthropic/claude-haiku-5.5',
            effort: '',
            reasons: false,
            onChanged: (model, effort) => picks.add('$model@$effort'),
            close: () {},
          ),
        ),
      ),
    );
    expect(find.text('Not used by this model'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-menu.effort')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-menu.effort.high')));
    await tester.pump();
    expect(picks, isEmpty);
  });

  testWidgets('Cupertino menus are popovers on desktop, not action sheets', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var picked = '';
    await tester.pumpWidget(
      _host(
        design: DesignLanguage.cupertino,
        AdaptiveMenuButton(
          actions: [
            MenuAction(label: 'Rename', onSelected: () => picked = 'rename'),
            MenuAction(label: 'Delete', destructive: true, onSelected: () => picked = 'delete'),
          ],
          child: const Text('More'),
        ),
      ),
    );
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.byType(c.CupertinoActionSheet), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(picked, 'delete');
    expect(find.text('Rename'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the effort level picks Efficient or Thorough, the only levels offered', (tester) async {
    final picks = <HarnessTier>[];
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 320,
          height: 700,
          child: AgentMenuPanel(
            groups: agentMenuGroups(_catalog),
            model: 'anthropic/claude-opus-5.5',
            effort: 'medium',
            onChanged: (_, _) {},
            close: () {},
            onLevel: picks.add,
          ),
        ),
      ),
    );
    expect(HarnessTier.offered, [HarnessTier.efficient, HarnessTier.thorough]);
    // On the Effort page, which the root row names it on.
    expect(find.text('Effort level'), findsNothing);
    expect(find.text('Medium · Efficient'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-menu.effort')));
    await tester.pump();
    expect(find.text('Effort level'), findsOneWidget);
    // Max is an effort row there, never a level.
    expect(
      find.descendant(of: find.byKey(const ValueKey('agent-menu.level')), matching: find.text('Max')),
      findsNothing,
    );
    await tester.tap(find.text('Thorough'));
    await tester.pump();
    expect(picks, [HarnessTier.thorough]);
    expect(find.text(HarnessTier.thorough.description), findsOneWidget);
  });

  group('the lead harness', () {
    const everyai = DriverInfo(id: 'everyai', label: 'EveryAI');
    const claude = DriverInfo(id: 'claude-code', label: 'Claude Code', needsConsent: true);
    const codex = DriverInfo(id: 'codex', label: 'Codex');
    const ready = DriverInfo(id: 'test', label: 'Test CLI');
    const leads = <LeadOption>[
      (info: everyai, blocked: null, detail: ''),
      (info: claude, blocked: 'Turn on in Settings', detail: '2.1.318'),
      (info: codex, blocked: 'Not built yet', detail: ''),
      (info: ready, blocked: null, detail: '1.0'),
    ];
    const testModels = [
      DriverModel(id: 'fast', label: 'Fast', isDefault: true, efforts: ['low', 'high']),
      DriverModel(id: 'deep', label: 'Deep'),
    ];

    testWidgets('blocked harnesses are greyed with the reason; a ready one swaps the model list', (tester) async {
      var harness = 'everyai';
      final picked = <String>[];
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 320,
              height: 700,
              child: AgentMenuPanel(
                groups: agentMenuGroups(_catalog),
                model: harness == 'everyai' ? 'anthropic/claude-opus-5.5' : 'fast',
                effort: '',
                onChanged: (m, e) => picked.add('$m@$e'),
                close: () {},
                onLevel: (_) {},
                leads: leads,
                harness: harness,
                onHarness: (h) => setState(() => harness = h),
                driverModels: harness == 'everyai' ? null : testModels,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('agent-menu.effort')));
      await tester.pump();
      expect(find.text('Effort level'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.back')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('agent-menu.harness')));
      await tester.pump();
      expect(find.text('Turn on in Settings'), findsOneWidget);
      expect(find.text('Not built yet'), findsOneWidget);
      // Greyed rows don't pick.
      await tester.tap(find.byKey(const ValueKey('agent-menu.harness.codex')));
      await tester.tap(find.byKey(const ValueKey('agent-menu.harness.claude-code')));
      await tester.pump();
      expect(harness, 'everyai');
      await tester.tap(find.byKey(const ValueKey('agent-menu.harness.test')));
      await tester.pump();
      expect(harness, 'test');
      // Back on the root: no effort level for an outside lead, and its own models.
      expect(find.text('Effort level'), findsNothing);
      expect(find.text('Test CLI'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.model')));
      await tester.pump();
      expect(find.text('Anthropic'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('agent-menu.model.deep')));
      await tester.pump();
      expect(picked, ['deep@']);
      await tester.tap(find.byKey(const ValueKey('agent-menu.effort')));
      await tester.pump();
      // Deep takes no effort; only the default is listed, and no EveryAI level.
      expect(find.byKey(const ValueKey('agent-menu.effort.low')), findsNothing);
      expect(find.text('Effort level'), findsNothing);
    });

    testWidgets('an outside lead without a model list runs its default', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 320,
            height: 700,
            child: AgentMenuPanel(
              groups: const [],
              model: '',
              effort: '',
              onChanged: (_, _) {},
              close: () {},
              leads: leads,
              harness: 'test',
              onHarness: (_) {},
              driverModels: const [],
            ),
          ),
        ),
      );
      expect(find.text('Its default model'), findsOneWidget);
      expect(find.text('Not used by this model'), findsOneWidget);
    });

    test('the Harness page lists EveryAI and installed harnesses, greyed with their fix', () {
      const gemini = DriverInfo(id: 'gemini', label: 'Gemini CLI');
      final options = leadOptions(
        [everyai, claude, codex, ready, gemini],
        {
          'claude-code': const DriverStatus(installed: true, signedIn: true, version: '2.1'),
          'codex': const DriverStatus(),
          'test': const DriverStatus(
            installed: true,
            signedIn: false,
            problem: 'Not signed in. Run `test login` in a terminal.',
          ),
        },
        const {},
        current: 'everyai',
      );
      expect(
        [for (final o in options) (o.info.id, o.blocked)],
        [
          ('everyai', null),
          ('claude-code', 'Turn on in Settings → Code → Harnesses'),
          ('test', 'Not signed in. Run `test login` in a terminal.'),
        ],
      );
      // The current pick stays even when it is gone.
      expect(
        [
          for (final o in leadOptions([everyai, codex], {}, const {}, current: 'codex')) o.blocked,
        ],
        [null, 'Checking…'],
      );
      expect(leadOptions([everyai, codex], null, const {}, current: 'everyai'), hasLength(1));
    });

    testWidgets('with only EveryAI there is no Harness row, but the check stays in reach', (tester) async {
      var checks = 0;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 320,
            height: 700,
            child: AgentMenuPanel(
              groups: agentMenuGroups(_catalog),
              model: 'anthropic/claude-opus-5.5',
              effort: '',
              onChanged: (_, _) {},
              close: () {},
              leads: const [(info: everyai, blocked: null, detail: '')],
              onHarness: (_) {},
              onCheckAgain: () => checks++,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('agent-menu.harness')), findsNothing);
      expect(find.byKey(const ValueKey('agent-menu.model')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.find-harnesses')));
      await tester.pump();
      expect(checks, 1);
    });

    testWidgets('Check again looks for harnesses again', (tester) async {
      var checks = 0;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 320,
            height: 700,
            child: AgentMenuPanel(
              groups: agentMenuGroups(_catalog),
              model: 'anthropic/claude-opus-5.5',
              effort: '',
              onChanged: (_, _) {},
              close: () {},
              leads: leads,
              onHarness: (_) {},
              onCheckAgain: () => checks++,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('agent-menu.harness')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('agent-menu.harness.check-again')));
      await tester.pump();
      expect(checks, 1);
      expect(find.byKey(const ValueKey('agent-menu.harness')), findsOneWidget);
    });

    testWidgets('in a session the harness is shown, not switched', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 320,
            height: 700,
            child: AgentMenuPanel(
              groups: agentMenuGroups(_catalog),
              model: 'anthropic/claude-opus-5.5',
              effort: '',
              onChanged: (_, _) {},
              close: () {},
              leads: const [(info: everyai, blocked: null, detail: '')],
            ),
          ),
        ),
      );
      expect(find.text('EveryAI · Switching comes later'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.harness')));
      await tester.pump();
      expect(find.byKey(const ValueKey('agent-menu.harness.everyai')), findsNothing);
    });
  });

  group('opened at one page (a composer part)', () {
    Future<({List<String> picks, List<String> closes})> show(
      WidgetTester tester,
      AgentMenuPage page, {
      List<DriverModel>? driverModels,
    }) async {
      final picks = <String>[];
      final closes = <String>[];
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 320,
            height: 700,
            child: AgentMenuPanel(
              key: ValueKey('$page${driverModels != null}'),
              initialPage: page,
              groups: agentMenuGroups(_catalog),
              model: driverModels == null ? 'anthropic/claude-opus-5.5' : 'fast',
              effort: 'medium',
              onChanged: (m, e) => picks.add('$m@$e'),
              close: () => closes.add('closed'),
              onLevel: (t) => picks.add(t.name),
              driverModels: driverModels,
            ),
          ),
        ),
      );
      return (picks: picks, closes: closes);
    }

    testWidgets('the Model page has no back row, and a pick closes it', (tester) async {
      final r = await show(tester, AgentMenuPage.model);
      expect(find.byKey(const ValueKey('agent-menu.back')), findsNothing);
      expect(find.byKey(const ValueKey('agent-menu.model')), findsNothing);
      expect(find.text('Anthropic'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.model.openai/gpt-6.1-sol')));
      await tester.pump();
      expect(r.picks, ['openai/gpt-6.1-sol@high']);
      expect(r.closes, ['closed']);
    });

    testWidgets('the Effort page carries the EveryAI level, not for an outside lead', (tester) async {
      final r = await show(tester, AgentMenuPage.effort);
      expect(find.byKey(const ValueKey('agent-menu.back')), findsNothing);
      expect(find.text('Effort level'), findsOneWidget);
      await tester.tap(find.text('Thorough'));
      await tester.pump();
      expect(r.picks, ['thorough']);
      // The level stays open for another pick; an effort closes the panel.
      expect(r.closes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('agent-menu.effort.high')));
      await tester.pump();
      expect(r.picks.last, 'anthropic/claude-opus-5.5@high');
      expect(r.closes, ['closed']);

      await show(
        tester,
        AgentMenuPage.effort,
        driverModels: const [
          DriverModel(id: 'fast', label: 'Fast', efforts: ['low', 'high']),
        ],
      );
      expect(find.text('Effort level'), findsNothing);
      expect(find.byKey(const ValueKey('agent-menu.effort.low')), findsOneWidget);
    });
  });
}
