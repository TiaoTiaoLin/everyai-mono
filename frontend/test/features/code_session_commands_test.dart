import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/agent_models.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/compaction.dart';
import 'package:every_ai/features/code/domain/session_commands.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:every_ai/features/code/ui/transcript/aside_card.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/slash/slash_command.dart';
import 'package:every_ai/features/slash/slash_registry.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<T> _until<T>(T Function() read, bool Function(T) cond, {Duration timeout = const Duration(seconds: 8)}) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

const _choices = [
  AgentChoice(model: 'anthropic/claude-sonnet-5.5', effort: 'medium', tier: 'everyday', label: 'Sonnet 5.5 · medium'),
  AgentChoice(model: 'anthropic/claude-opus-5.5', effort: 'medium', tier: 'everyday', label: 'Opus 5.5 · medium'),
  AgentChoice(model: 'anthropic/claude-opus-5.5', effort: 'high', tier: 'hard', label: 'Opus 5.5 · high'),
  AgentChoice(model: 'openai/gpt-6.1-sol', effort: 'low', tier: 'everyday', label: 'GPT-6.1 Sol · low'),
];

void main() {
  group('arguments', () {
    test('effort names', () {
      expect(codeEffortArg('High'), 'high');
      expect(codeEffortArg('xhigh'), 'xhigh');
      expect(codeEffortArg('extra'), 'xhigh');
      expect(codeEffortArg('default'), '');
      expect(codeEffortArg('auto'), '');
      expect(codeEffortArg('turbo'), isNull);
    });

    test('a model name picks a curated choice, at the effort named', () {
      expect(agentChoiceFor('sonnet', _choices)!.label, 'Sonnet 5.5 · medium');
      expect(agentChoiceFor('Opus', _choices)!.effort, 'medium');
      expect(agentChoiceFor('opus high', _choices)!.effort, 'high');
      expect(agentChoiceFor('opus max', _choices)!.effort, 'medium'); // no such pairing: the first
      expect(agentChoiceFor('gpt-6.1', _choices)!.model, 'openai/gpt-6.1-sol');
      expect(agentChoiceFor('gemini', _choices), isNull);
      expect(agentChoiceFor('high', _choices), isNull);
      expect(agentChoiceFor('', _choices), isNull);
    });

    test('rewind counts back from the latest turn', () {
      expect(rewindTarget(3, ''), 3);
      expect(rewindTarget(3, '1'), 3);
      expect(rewindTarget(3, '2'), 2);
      expect(rewindTarget(3, '9'), 1);
      expect(rewindTarget(3, 'two'), isNull);
      expect(rewindTarget(3, '0'), isNull);
      expect(rewindTarget(0, ''), isNull);
    });
  });

  group('btw request', () {
    test('carries the session record and the question, and nothing for the agent', () {
      final events = [
        HarnessEvent.decode({
          'kind': 'MessageEvent',
          'id': 'u1',
          'source': 'user',
          'llm_message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': modeNote(AgentMode.ask, 'Add a decrement button')},
            ],
          },
        }),
        HarnessEvent.decode({
          'kind': 'MessageEvent',
          'id': 'a1',
          'source': 'agent',
          'llm_message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Reading lib/counter.dart first.'},
            ],
          },
        }),
        const ConnectionChange(connected: true),
      ];
      final record = renderSessionRecord(events);
      expect(record, contains('[user]\nAdd a decrement button'));
      expect(record, contains('[agent]\nReading lib/counter.dart first.'));
      expect(record, isNot(contains('everyai-mode')));

      final messages = btwRequest(record: record, question: 'Which file is it editing?');
      expect(messages.first['role'], 'system');
      final user = messages.last['content']! as String;
      expect(user, contains('<session-record>\n[user]'));
      expect(user, endsWith('Side question: Which file is it editing?'));
      expect(btwRequest(record: '', question: 'x').last['content'], contains('(nothing has happened yet)'));
    });

    test('a long record keeps the newest part', () {
      final events = [
        for (var i = 0; i < 50; i++)
          HarnessEvent.decode({
            'kind': 'MessageEvent',
            'id': 'a$i',
            'source': 'agent',
            'llm_message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'step $i ${'x' * 200}'},
              ],
            },
          }),
      ];
      final record = renderSessionRecord(events, maxChars: 2000);
      expect(record.length, lessThan(2100));
      expect(record, startsWith('[earlier steps omitted]'));
      expect(record, contains('step 49'));
      expect(record, isNot(contains('step 0 ')));
    });
  });

  group('controller', () {
    late AppDatabase db;
    late ProviderContainer container;
    late FakeHarness harness;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([
        const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
      ]);
      harness = FakeHarness(step: Duration.zero);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          harnessProvider.overrideWithValue(harness),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<String> startDemo() async {
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
      return info.id;
    }

    test('/btw answers beside the session without sending the agent anything', () async {
      final id = await startDemo();
      final controller = container.read(codeSessionProvider(id).notifier);
      final turnsBefore = container.read(codeSessionProvider(id)).transcript.items.whereType<UserTurn>().length;
      List<Map<String, Object?>>? asked;
      final answer = Completer<String>();
      final pending = controller.askAside(
        'What is it asking me?',
        summarizer: (messages) {
          asked = messages;
          return answer.future;
        },
      );
      var asides = container.read(codeSessionProvider(id)).asides;
      expect(asides.single.busy, isTrue);
      expect(asides.single.question, 'What is it asking me?');
      answer.complete('  It wants to know where the button goes.  ');
      await pending;

      asides = container.read(codeSessionProvider(id)).asides;
      expect(asides.single.busy, isFalse);
      expect(asides.single.answer, 'It wants to know where the button goes.');
      expect(asked!.last['content'], contains('Add decrement'));
      expect(asked!.last['content'], endsWith('Side question: What is it asking me?'));
      // The agent's conversation is untouched and its question is still open.
      final t = container.read(codeSessionProvider(id)).transcript;
      expect(t.items.whereType<UserTurn>().length, turnsBefore);
      expect(t.openQuestion, isNotNull);

      controller.dismissAside(asides.single.id);
      expect(container.read(codeSessionProvider(id)).asides, isEmpty);
    });

    test('/btw shows a failure in its card', () async {
      final id = await startDemo();
      final controller = container.read(codeSessionProvider(id).notifier);
      await controller.askAside('x', summarizer: (_) async => throw const HarnessError('402 out of credits'));
      expect(container.read(codeSessionProvider(id)).asides.single.error, contains('402'));
      // Without a stand-in model the demo has nothing to ask.
      await controller.askAside('y');
      expect(container.read(codeSessionProvider(id)).asides.last.error, contains('real session'));
    });

    test('/cost adds one usage card', () async {
      final id = await startDemo();
      final controller = container.read(codeSessionProvider(id).notifier);
      controller.showCost();
      controller.showCost();
      final asides = container.read(codeSessionProvider(id)).asides;
      expect(asides.single.kind, AsideKind.cost);
    });

    test('/model and /effort switch the live conversation and the saved session', () async {
      final id = await startDemo();
      final controller = container.read(codeSessionProvider(id).notifier);
      CodeSessionInfo info() => container.read(codeSessionsProvider.notifier).byId(id)!;

      expect(await controller.switchModel(model: 'anthropic/claude-opus-5.5', effort: 'high'), startsWith('Now using'));
      expect(info().model, 'anthropic/claude-opus-5.5');
      expect(info().effort, 'high');
      expect(await controller.switchModel(effort: ''), startsWith('Now using'));
      expect(info().effort, '');
      expect(info().model, 'anthropic/claude-opus-5.5');
      expect(await controller.switchModel(effort: ''), 'Already using that.');
      expect(harness.switched, ['anthropic/claude-opus-5.5@high', 'anthropic/claude-opus-5.5@']);
    });
  });

  group('CodeComposer commands', () {
    final calls = <String>[];
    Widget host() => ProviderScope(
      overrides: [slashCommandsProvider.overrideWithValue(builtInSlashCommands)],
      child: m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: CodeComposer(
                busy: true,
                mode: AgentMode.plan,
                onModeChanged: (_) {},
                onSend: (text, _) => calls.add('send|$text'),
                slashHost: CodeSlashHost(
                  setMode: (m) => calls.add('mode|$m'),
                  stop: () => calls.add('stop'),
                  build: (a) => calls.add('build|$a'),
                  setModel: (a) => calls.add('model|$a'),
                  setEffort: (a) => calls.add('effort|$a'),
                  clear: (a) => calls.add('clear|$a'),
                  compact: (a) => calls.add('compact|$a'),
                  rewind: (a) => calls.add('rewind|$a'),
                  cost: () => calls.add('cost'),
                  btw: (a) => calls.add('btw|$a'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('each session command reaches the session', (tester) async {
      await tester.pumpWidget(host());
      Future<void> run(String line) async {
        await tester.enterText(find.byType(EditableText), line);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
      }

      for (final line in [
        '/btw what is it testing?',
        '/model opus high',
        '/effort max',
        '/compact keep the API notes',
        '/rewind 2',
        '/cost',
        '/stop',
        '/build ',
        '/clear start over',
        '/plan ',
      ]) {
        await run(line);
      }
      expect(calls, [
        'btw|what is it testing?',
        'model|opus high',
        'effort|max',
        'compact|keep the API notes',
        'rewind|2',
        'cost',
        'stop',
        'build|',
        'clear|start over',
        'mode|plan',
      ]);
      expect(find.text('/btw what is it testing?'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  testWidgets('aside cards show the answer, the failure or the usage, and dismiss', (tester) async {
    var dismissed = 0;
    Widget card(Aside aside, {UsageTotals usage = UsageTotals.zero}) => m.MaterialApp(
      home: m.Material(
        child: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
          child: AsideCard(aside: aside, usage: usage, onDismiss: () => dismissed++),
        ),
      ),
    );
    const q = Aside(id: 1, kind: AsideKind.btw, question: 'Why?');
    await tester.pumpWidget(card(q.done('Because tests.')));
    expect(find.text('By the way: Why?'), findsOneWidget);
    expect(find.textContaining('Because tests.', findRichText: true), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    expect(dismissed, 1);

    await tester.pumpWidget(card(q.failed('402 out of credits')));
    expect(find.text('402 out of credits'), findsOneWidget);

    await tester.pumpWidget(card(const Aside(id: 2, kind: AsideKind.cost)));
    expect(find.text('No model calls yet.'), findsOneWidget);
    await tester.pumpWidget(
      card(
        const Aside(id: 2, kind: AsideKind.cost),
        usage: const UsageTotals(calls: 3, promptTokens: 12000, completionTokens: 800, chargedMicros: 4200),
      ),
    );
    expect(find.text('Model calls'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}
