import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/slash/code_commands.dart';
import 'package:every_ai/features/slash/native_commands.dart';
import 'package:every_ai/features/slash/slash_command.dart';
import 'package:every_ai/features/slash/slash_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  final ran = <String>[];
  SlashCommand cmd(
    String name,
    String description, {
    SlashGroup group = SlashGroup.builtIn,
    SlashScope scope = SlashScope.both,
    String? argsHint,
  }) => SlashCommand(
    name: name,
    description: description,
    group: group,
    scope: scope,
    argsHint: argsHint,
    run: (ctx, args) => ran.add('$name|$args'),
  );

  final commands = [
    cmd('review', 'Review the diff with a subagent', group: SlashGroup.custom),
    cmd('plan', 'Switch to Plan mode', scope: SlashScope.code, argsHint: '[what to plan]'),
    cmd('pdf-tools', 'Fill and merge PDFs', group: SlashGroup.skills),
    cmd('search', 'Search the web', scope: SlashScope.chat),
    cmd('stop', 'Stop the agent', scope: SlashScope.code),
    cmd('compact', 'Summarize to free context'),
  ];

  setUp(ran.clear);

  group('slashQuery', () {
    TextEditingValue at(String text, [int? caret]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret ?? text.length),
    );

    test('opens only for a slash at the start, with the caret in the first word', () {
      expect(slashQuery(at('/')), '');
      expect(slashQuery(at('/pl')), 'pl');
      expect(slashQuery(at('/plan now')), isNull);
      expect(slashQuery(at('hi /plan')), isNull);
      expect(slashQuery(at(' /plan')), isNull);
      expect(slashQuery(at('/plan', 3)), isNull);
      expect(slashQuery(at('/pl x', 3)), 'pl');
    });
  });

  group('filterSlashCommands', () {
    test('keeps the scope, groups in order and ranks prefix over substring over description', () {
      final names = [for (final c in filterSlashCommands(commands, '', SlashScope.code)) c.name];
      expect(names, ['compact', 'plan', 'stop', 'review', 'pdf-tools']);
      expect(
        [for (final c in filterSlashCommands(commands, '', SlashScope.chat)) c.name],
        ['compact', 'search', 'review', 'pdf-tools'],
      );
      expect(
        [for (final c in filterSlashCommands(commands, 'p', SlashScope.code)) c.name],
        ['plan', 'compact', 'stop', 'pdf-tools'],
      );
      expect([for (final c in filterSlashCommands(commands, 'PDF', SlashScope.code)) c.name], ['pdf-tools']);
      expect([for (final c in filterSlashCommands(commands, 'subagent', SlashScope.code)) c.name], ['review']);
      expect(filterSlashCommands(commands, 'zzz', SlashScope.code), isEmpty);
    });

    test('an exact name beats a description match in an earlier group', () {
      final list = [
        cmd('search', 'Search the web for an answer', scope: SlashScope.chat),
        cmd('web', 'Open my web notes', group: SlashGroup.custom),
        cmd('clear', 'Start a fresh session', scope: SlashScope.code),
        cmd('session', 'Mine', group: SlashGroup.custom),
      ];
      expect([for (final c in filterSlashCommands(list, 'web', SlashScope.chat)) c.name], ['web', 'search']);
      expect([for (final c in filterSlashCommands(list, 'session', SlashScope.code)) c.name], ['session', 'clear']);
      expect(parseSlashLine('/web', list, SlashScope.chat)!.command.name, 'web');
      // A name match in a later group also beats a description match.
      expect([for (final c in filterSlashCommands(list, 'we', SlashScope.chat)) c.name], ['web', 'search']);
    });

    test('an earlier group shadows the same name', () {
      final list = [cmd('learn', 'skill', group: SlashGroup.skills), cmd('learn', 'built-in')];
      expect(filterSlashCommands(list, 'le', SlashScope.chat).single.description, 'built-in');
    });
  });

  test('parseSlashLine finds known commands with their arguments', () {
    final line = parseSlashLine('/plan add a login page\nwith tests', commands, SlashScope.code)!;
    expect(line.command.name, 'plan');
    expect(line.args, 'add a login page\nwith tests');
    expect(parseSlashLine('/search x', commands, SlashScope.code), isNull);
    expect(parseSlashLine('/etc/hosts is odd', commands, SlashScope.code), isNull);
    expect(parseSlashLine('/stop', commands, SlashScope.code)!.args, '');
  });

  group('CodeComposer', () {
    final sent = <String>[];
    AgentMode? mode;

    Widget host({
      List<SlashCommand>? native,
      CodeSlashHost? slashHost,
      List<SlashCommand>? everyai,
      Future<String?> Function(String name, String args)? unlisted,
    }) => ProviderScope(
      overrides: [slashCommandsProvider.overrideWithValue(everyai ?? commands)],
      child: m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: CodeComposer(
                busy: false,
                mode: AgentMode.ask,
                onModeChanged: (m) => mode = m,
                onSend: (text, _) => sent.add(text),
                commands: native,
                slashHost: slashHost,
                onUnlistedCommand: unlisted,
              ),
            ),
          ),
        ),
      ),
    );

    setUp(() {
      sent.clear();
      mode = null;
    });

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(EditableText), text);
      await tester.pump();
    }

    Finder row(String name) => find.text('/$name');

    // Desktop key handling: Enter sends.
    void desktop(String description, WidgetTesterCallback body) =>
        testWidgets(description, body, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    desktop('typing / lists commands grouped; typing more filters', (tester) async {
      await tester.pumpWidget(host());
      expect(row('plan'), findsNothing);

      await type(tester, '/');
      for (final n in ['compact', 'plan', 'stop', 'review', 'pdf-tools']) {
        expect(row(n), findsOneWidget);
      }
      expect(row('search'), findsNothing);
      expect(find.text('Built-in'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
      expect(find.text('Skills'), findsOneWidget);
      expect(find.text('Connectors'), findsNothing);
      expect(find.text('[what to plan]'), findsOneWidget);

      await type(tester, '/st');
      expect(row('stop'), findsOneWidget);
      expect(row('plan'), findsNothing);

      await type(tester, '/st now');
      expect(row('stop'), findsNothing);
    });

    desktop('arrows move, Enter runs, Tab completes commands that take arguments', (tester) async {
      await tester.pumpWidget(host());
      await type(tester, '/');
      // compact, plan, stop, …: down twice lands on stop; up once is plan.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(ran, isEmpty);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.controller.text, '/plan ');
      expect(row('plan'), findsNothing);

      await tester.enterText(find.byType(EditableText), '/plan add auth');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(ran, ['plan|add auth']);
      expect(sent, isEmpty);
      expect(field.controller.text, '');

      // Wraps from the top to the last row; Enter runs a command without arguments.
      await type(tester, '/');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(ran.last, 'stop|');
      expect(mode, isNull);
    });

    desktop('Esc closes the menu until the word changes; tapping a row picks it', (tester) async {
      await tester.pumpWidget(host());
      await type(tester, '/c');
      expect(row('compact'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(row('compact'), findsNothing);

      await type(tester, '/co');
      expect(row('compact'), findsOneWidget);
      await tester.tap(row('compact'));
      await tester.pump();
      expect(ran, ['compact|']);
    });

    group('an outside harness', () {
      final nativeRan = <String>[];
      final native = nativeSlashCommands(
        const [
          NativeCommand(name: 'review', description: 'Review changes'),
          NativeCommand(name: 'web', description: 'Search the web', argsHint: '<query>'),
        ],
        (name, args) async {
          nativeRan.add('$name|$args');
          return null;
        },
      );
      final calls = <String>[];
      final slashHost = CodeSlashHost(
        setMode: (_) {},
        rewind: (a) => calls.add('rewind|$a'),
        commit: (a) => calls.add('commit|$a'),
        pr: (a) => calls.add('pr|$a'),
        cost: () => calls.add('cost'),
        morning: () => calls.add('morning'),
      );
      setUp(() {
        nativeRan.clear();
        calls.clear();
      });

      desktop("the menu lists only the harness's commands; one runs natively, an unlisted one is a message", (
        tester,
      ) async {
        await tester.pumpWidget(host(native: native, slashHost: slashHost));
        await type(tester, '/');
        expect(row('review'), findsOneWidget);
        expect(row('web'), findsOneWidget);
        for (final n in ['compact', 'plan', 'stop', 'pdf-tools']) {
          expect(row(n), findsNothing);
        }
        expect(find.text('Commands'), findsOneWidget);
        expect(find.text('Built-in'), findsNothing);

        await type(tester, '/review x');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(nativeRan, ['review|x']);
        expect(sent, isEmpty);

        await type(tester, '/plan now');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(sent, ['/plan now']);
        expect(ran, isEmpty);
      });

      desktop('before the harness lists its commands, a typed /name still goes to it as a command', (tester) async {
        final typed = <String>[];
        await tester.pumpWidget(
          host(
            native: const [],
            slashHost: slashHost,
            unlisted: (name, args) async {
              typed.add('$name|$args');
              return null;
            },
          ),
        );
        await type(tester, '/compress now');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(typed, ['compress|now']);
        expect(sent, isEmpty);

        await type(tester, '/usr/bin is slow');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(sent, ['/usr/bin is slow']);
      });

      desktop('a command refused while the agent works goes back in the box', (tester) async {
        final busy = nativeSlashCommands(const [
          NativeCommand(name: 'review'),
        ], (_, _) async => 'The agent is working.');
        await tester.pumpWidget(host(native: busy, slashHost: slashHost));
        await type(tester, '/review the auth changes');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.text('/review the auth changes'), findsOneWidget);
        expect(find.text('The agent is working.'), findsOneWidget);
        await tester.pumpAndSettle(const Duration(seconds: 10));
      });

      desktop('the app actions are a menu whose rows call what their / commands call', (tester) async {
        await tester.pumpWidget(host(native: native, slashHost: slashHost));
        for (final (label, call) in [
          ('Rewind last turn', 'rewind|'),
          ('Commit…', 'commit|'),
          ('Pull request…', 'pr|'),
          ('Cost', 'cost'),
          ('Morning brief', 'morning'),
        ]) {
          await tester.tap(find.byType(SessionActionsButton));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(calls.last, call);
        }
        expect(calls, hasLength(5));
      });

      desktop('an EveryAI session has no actions menu', (tester) async {
        await tester.pumpWidget(host(slashHost: slashHost));
        expect(find.byType(SessionActionsButton), findsNothing);
      });

      desktop('in an EveryAI session the / commands make the same calls as those rows', (tester) async {
        await tester.pumpWidget(host(slashHost: slashHost, everyai: codeBuiltIns));
        // A space after the name shuts the menu, so Enter runs the line (/rewind takes arguments).
        for (final name in ['rewind', 'commit', 'pr', 'cost', 'morning']) {
          await type(tester, '/$name ');
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
        }
        expect(calls, ['rewind|', 'commit|', 'pr|', 'cost', 'morning']);
      });
    });

    desktop('unknown commands and paths are sent as messages', (tester) async {
      await tester.pumpWidget(host());
      await type(tester, '/etc/hosts looks wrong');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, ['/etc/hosts looks wrong']);
      expect(ran, isEmpty);
    });
  });
}
