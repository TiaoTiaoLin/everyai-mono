import 'dart:async';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/chat/domain/reasoning_effort.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/slash/chat_actions.dart';
import 'package:every_ai/features/slash/chat_commands.dart';
import 'package:every_ai/features/slash/skills/skill_md.dart';
import 'package:every_ai/features/slash/slash_command.dart';
import 'package:every_ai/features/slash/slash_registry.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements ChatTransport {
  final requests = <ChatRequest>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) {
    requests.add(request);
    return Stream.fromIterable(const [TextDelta('ok'), TurnDone()]);
  }
}

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

void main() {
  group('forced tools', () {
    test('every make-command names a tool the backend defines', () {
      const known = {
        'make_slides',
        'make_quiz',
        'make_flashcards',
        'render_diagram',
        'render_svg',
        'generate_image',
        'create_artifact',
      };
      expect(forcedTools.values.map((f) => f.tool).toSet(), known);
      for (final name in forcedTools.keys) {
        expect(chatBuiltIns.where((c) => c.name == name), hasLength(1), reason: name);
      }
    });

    test('the built-in set covers the chat commands and keeps Code ones out of chat', () {
      final names = chatBuiltIns.map((c) => c.name).toSet();
      expect(
        names,
        containsAll([
          'chat',
          'search',
          'research',
          'model',
          'effort',
          'new',
          'retry',
          'memory',
          'connectors',
          'export',
          'learn',
        ]),
      );
      expect(chatBuiltIns.every((c) => c.scope == SlashScope.chat), isTrue);
      expect(
        builtInSlashCommands.where((c) => c.scope == SlashScope.code).map((c) => c.name),
        containsAll(['plan', 'stop']),
      );
    });
  });

  group('helpers', () {
    test('parseEffortArg', () {
      expect(parseEffortArg(' High '), ReasoningEffort.high);
      expect(parseEffortArg('default'), ReasoningEffort.auto);
      expect(parseEffortArg('turbo'), isNull);
    });

    test('modelForQuery finds a model by alias or prefix', () {
      final spec = builtInCatalog.mentionSuggestions('').first.$2;
      final name = spec.id.value.split('/').last;
      expect(modelForQuery(builtInCatalog, name), spec);
      expect(modelForQuery(builtInCatalog, '@$name'), spec);
      expect(modelForQuery(builtInCatalog, 'no-such-model-xyz'), isNull);
      expect(modelForQuery(builtInCatalog, '  '), isNull);
    });

    test('skillContext wraps the body and asks for its use', () {
      final c = skillContext('weekly-report', '  Steps\n1. Gather.\n');
      expect(c, startsWith('<skill name="weekly-report">\nSteps'));
      expect(c, contains('</skill>'));
    });

    test('chatToMarkdown writes turns, notes tools and skips unfinished empties', () {
      final t = DateTime(2026);
      Message m(Role role, List<MessagePart> parts, {MessageStatus status = MessageStatus.complete}) =>
          Message(id: '${parts.hashCode}', conversationId: 'c', role: role, parts: parts, createdAt: t, status: status);
      final md = chatToMarkdown('Rivers', [
        m(Role.user, [const TextPart('Quiz me')]),
        m(Role.assistant, [
          const TextPart('Here you go.'),
          const ToolCallPart(toolName: 'make_quiz', argumentsJson: '{}'),
        ]),
        m(Role.assistant, const [], status: MessageStatus.failed),
      ]);
      expect(md, startsWith('# Rivers\n'));
      expect(md, contains('## You\n\nQuiz me'));
      expect(md, contains('## Assistant\n\nHere you go.'));
      expect(md, contains('_Made a quiz_'));
      expect('## Assistant'.allMatches(md), hasLength(1));
      expect(chatToMarkdown('', const []), '# Chat\n');
    });
  });

  group('SkillMd', () {
    const good = '---\nname: weekly-report\ndescription: Writes the weekly report.\n---\n# Weekly report\n1. Gather.\n';

    test('parses and round-trips', () {
      final s = SkillMd.parse(good);
      expect(s.name, 'weekly-report');
      expect(s.description, 'Writes the weekly report.');
      expect(s.body, startsWith('# Weekly report'));
      expect(SkillMd.parse(s.toSource()).description, s.description);
    });

    test('rejects what the Agent Skills format does not allow', () {
      String skill(String name, [String desc = 'Does it.', String body = 'Steps.']) =>
          '---\nname: $name\ndescription: $desc\n---\n$body';
      expect(() => SkillMd.parse('no front matter'), throwsFormatException);
      expect(() => SkillMd.parse(skill('Bad Name')), throwsFormatException);
      expect(() => SkillMd.parse(skill('-lead')), throwsFormatException);
      expect(() => SkillMd.parse(skill('a--b')), throwsFormatException);
      expect(() => SkillMd.parse(skill('a' * 65)), throwsFormatException);
      expect(() => SkillMd.parse(skill('ok', '')), throwsFormatException);
      expect(() => SkillMd.parse(skill('ok', 'x' * 1025)), throwsFormatException);
      expect(() => SkillMd.parse(skill('ok', 'Does it.', '')), throwsFormatException);
    });

    test('repairAndParse fixes a loose name and a long description, nothing else', () {
      final s = SkillMd.repairAndParse('---\nname: "Weekly Report!"\ndescription: ${'x' * 1100}\n---\nSteps.');
      expect(s.name, 'weekly-report');
      expect(s.description.length, 1024);
      expect(() => SkillMd.repairAndParse('---\nname: !!!\ndescription: d\n---\nSteps.'), throwsFormatException);
      expect(() => SkillMd.repairAndParse('just text'), throwsFormatException);
    });

    test('a description with a colon survives the round trip', () {
      const s = SkillMd(name: 'a', description: 'Use when: asked "why"', body: 'Steps.');
      expect(SkillMd.parse(s.toSource()).description, 'Use when: asked "why"');
    });
  });

  group('commands run against a host', () {
    Future<(SlashContext, List<String>)> context(WidgetTester tester, {ChatSlashHost? host}) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        m.MaterialApp(
          home: m.Scaffold(
            body: m.Material(
              child: EveryThemeScope(
                theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
                child: Builder(
                  builder: (c) {
                    ctx = c;
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final log = <String>[];
      final h =
          host ??
          ChatSlashHost(
            setMode: (m) => log.add('mode:$m'),
            sendWith: (text, {forceTool, context}) => log.add('send:$text|$forceTool|${context ?? ''}'),
            stage: (label, c) => log.add('stage:$label'),
            newChat: () => log.add('new'),
            retry: () => log.add('retry'),
            openMemory: () => log.add('memory'),
            exportChat: (f) => log.add('export:$f'),
            saveAsSkill: (h) => log.add('learn:$h'),
            setModel: (q) {
              log.add('model:$q');
              return null;
            },
            openModelPicker: () => log.add('picker'),
            setEffort: (e) {
              log.add('effort:$e');
              return null;
            },
          );
      return (
        SlashContext(
          context: ctx,
          surface: SlashScope.chat,
          setDraft: (_) {},
          send: (t) => log.add('plain:$t'),
          chat: h,
        ),
        log,
      );
    }

    SlashCommand find(String name) => chatBuiltIns.firstWhere((c) => c.name == name);

    testWidgets('make commands force their tool; mode commands switch then send', (tester) async {
      final (ctx, log) = await context(tester);
      await find('quiz').run(ctx, 'rivers');
      await find('slides').run(ctx, 'the Roman empire');
      await find('doc').run(ctx, 'a cover letter');
      await find('search').run(ctx, 'zig news');
      expect(log, [
        'send:rivers|make_quiz|',
        'send:the Roman empire|make_slides|',
        'send:a cover letter|create_artifact|',
        'mode:search',
        'plain:zig news',
      ]);
    });

    testWidgets('control commands reach the host', (tester) async {
      final (ctx, log) = await context(tester);
      await find('new').run(ctx, '');
      await find('retry').run(ctx, '');
      await find('memory').run(ctx, '');
      await find('export').run(ctx, 'pdf');
      await find('learn').run(ctx, 'weekly reports');
      await find('model').run(ctx, 'sonnet');
      await find('model').run(ctx, '');
      await find('effort').run(ctx, 'high');
      expect(log, [
        'new',
        'retry',
        'memory',
        'export:pdf',
        'learn:weekly reports',
        'model:sonnet',
        'picker',
        'effort:high',
      ]);
    });

    testWidgets('a skill command sends with the skill, or holds it for the next message', (tester) async {
      final (ctx, log) = await context(tester);
      final skill = skillSlashCommand(name: 'weekly-report', description: 'Reports', body: 'Steps.');
      expect(skill.group, SlashGroup.skills);
      await skill.run(ctx, 'for week 44');
      await skill.run(ctx, '');
      expect(log.first, startsWith('send:for week 44|null|<skill name="weekly-report">'));
      expect(log.last, 'stage:weekly-report');
    });
  });

  group('the controller sends force_tool and skill context', () {
    late AppDatabase db;
    late _Transport transport;
    late ProviderContainer container;
    const id = 'conv-slash';

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      transport = _Transport();
      final prefs = await Preferences.load(db);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          installedSkillsProvider.overrideWith(NoInstalledSkills.new),
          chatTransportProvider.overrideWithValue(transport),
          appToolCheckerProvider.overrideWithValue(const AppToolChecker()),
          modelCatalogProvider.overrideWith(_Catalog.new),
        ],
      );
      container.listen(chatSessionProvider(id), (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      container.dispose();
      await db.close();
    });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));
    ChatController ctl() => container.read(chatSessionProvider(id).notifier);
    ChatSessionState state() => container.read(chatSessionProvider(id));

    test('a forced tool turns tools on and keeps the mode, which has tools too', () async {
      ctl()
        ..setToolsEnabled(false)
        ..setMode(ChatMode.research);
      await ctl().send('rivers', forceTool: 'make_quiz');
      await settle();
      expect(transport.requests.single.forceTool, 'make_quiz');
      expect(transport.requests.single.toolsEnabled, isTrue);
      expect(transport.requests.single.mode, ChatMode.research);

      await ctl().send('thanks');
      await settle();
      expect(transport.requests.last.forceTool, isNull);
    });

    test('skill context rides in the prompt, not in the saved message, and is used once', () async {
      ctl().stageContext('<skill name="x">Steps.</skill>');
      await ctl().send('write it');
      await settle();
      expect(transport.requests.last.prompt, startsWith('<skill name="x">Steps.</skill>'));
      expect(transport.requests.last.prompt, endsWith('write it'));
      expect(state().messages.first.plainText, 'write it');

      await ctl().send('again');
      await settle();
      expect(transport.requests.last.prompt, 'again');

      await ctl().send('direct', context: 'CTX');
      await settle();
      expect(transport.requests.last.prompt, 'CTX\n\ndirect');
    });
  });
}
