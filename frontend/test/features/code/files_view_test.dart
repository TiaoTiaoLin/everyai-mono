import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/panes/file_tree.dart' show folderCap, textOpenCommand;
import 'package:every_ai/features/code/panes/panes_providers.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:every_ai/features/code/ui/console/bottom_drawer.dart';
import 'package:every_ai/features/code/ui/console/console_layout.dart';
import 'package:every_ai/features/code/ui/console/console_state.dart';
import 'package:every_ai/features/code/ui/console/files_view.dart';
import 'package:every_ai/features/code/ui/console/git_button.dart';
import 'package:every_ai/features/code/ui/console/session_info_view.dart';
import 'package:every_ai/features/code/ui/panes/terminal_pane.dart' show terminalKeys;
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<void> _git(String dir, List<String> args) async {
  final r = await Process.run('git', ['-C', dir, ...args]);
  if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
}

/// The first value of [p] that meets [cond], now or when it changes.
Future<T> _when<T>(ProviderContainer c, ProviderListenable<T> p, bool Function(T) cond) {
  final done = Completer<T>();
  final sub = c.listen<T>(p, (_, v) {
    if (cond(v) && !done.isCompleted) done.complete(v);
  }, fireImmediately: true);
  return done.future.whenComplete(sub.close);
}

/// Opens files without the disk, so a test can open one from a tap under the fake clock.
final class _NoDiskEditor extends FilesEditor {
  _NoDiskEditor(super.sessionId);

  @override
  Future<void> open(String path) async => state = FilesBuffer(path: path, text: 'x', opened: 'x');
}

Widget _app(Widget child) => m.MaterialApp(
  home: m.Material(
    child: EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child),
  ),
);

void main() {
  late AppDatabase db;
  late Directory tmp;
  late Preferences prefs;
  late CodeSessionInfo info;
  late ProviderContainer container;

  /// Lists [dir] in real time (it is disk and git), before the view asks for it: a listing started under the
  /// test's fake clock would never finish.
  Future<void> listed(WidgetTester tester, String dir) async {
    await tester.runAsync(() {
      container.listen(filesFolderProvider(dir), (_, _) {});
      return container.read(filesFolderProvider(dir).future);
    });
  }

  /// A worktree session over a repository with a changed and an added file under lib/, ignored files and folders,
  /// and a folder over the listing cap.
  Future<void> setUpRepo(WidgetTester tester, {List<Override> overrides = const []}) async {
    db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      prefs = await Preferences.load(db);
      tmp = await Directory.systemTemp.createTemp('everyai-files');
      final repo = '${tmp.path}/app';
      await Directory('$repo/lib').create(recursive: true);
      await _git(repo, ['init', '-q', '-b', 'main']);
      await _git(repo, ['config', 'user.name', 'Dev']);
      await _git(repo, ['config', 'user.email', 'dev@example.com']);
      File('$repo/lib/a.dart').writeAsStringSync('void main() {\n  print(1);\n}\n');
      File('$repo/lib/b.dart').writeAsStringSync('// b\n');
      File('$repo/README.md').writeAsStringSync('# App\n');
      File('$repo/.gitignore').writeAsStringSync('build/\n*.log\n');
      await _git(repo, ['add', '-A']);
      await _git(repo, ['commit', '-q', '-m', 'Initial commit']);
      final w = await GitService.createWorktree(
        repoRoot: repo,
        slug: 'files-abc123',
        worktreesDir: '${tmp.path}/worktrees',
        hooksDir: '${tmp.path}/hooks',
      );
      File('${w.path}/lib/a.dart').writeAsStringSync('void main() {\n  print(2);\n}\n');
      File('${w.path}/lib/new.dart').writeAsStringSync('// new\n');
      File('${w.path}/debug.log').writeAsStringSync('log\n');
      await Directory('${w.path}/build').create();
      File('${w.path}/build/out.txt').writeAsStringSync('out\n');
      await Directory('${w.path}/many').create();
      for (var i = 0; i < folderCap + 5; i++) {
        File('${w.path}/many/f$i.txt').writeAsStringSync('');
      }
      info = CodeSessionInfo(
        id: 's1',
        projectId: 'p1',
        title: 'Files',
        conversationId: 'c1',
        model: 'anthropic/claude-haiku-5.5',
        mode: AgentMode.ask,
        workingDir: w.path,
        createdAt: DateTime(2026),
        branch: w.branch,
        worktree: w,
      );
      prefs['code.sessions'] = jsonEncode([info.toJson()]);
    });
    addTearDown(() => tmp.delete(recursive: true));
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        modelCatalogProvider.overrideWith(_FixedCatalog.new),
        codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
        gitButtonProvider.overrideWith((ref, id) async => null),
        sessionRemoteLineProvider.overrideWithValue('Off'),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() => container.read(codeGitProvider('s1').future));
    for (final dir in ['', '/lib', '/build', '/many']) {
      await listed(tester, '${info.workingDir}$dir');
    }
  }

  String path(String rel) => '${info.workingDir}/$rel';
  Finder row(String rel) => find.byKey(ValueKey('files.row.$rel'));

  testWidgets('the tree marks changes, dims ignored files, lists folders when opened and caps big ones', (
    tester,
  ) async {
    await setUpRepo(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(FilesView(session: info)),
      ),
    );
    await tester.pump();

    expect(row('lib'), findsOneWidget);
    expect(row('README.md'), findsOneWidget);
    // Nothing below a folder is listed until it opens.
    expect(row('lib/a.dart'), findsNothing);
    expect(find.byKey(const ValueKey('files.dot.lib')), findsOneWidget);
    expect(find.byKey(const ValueKey('files.dot.build')), findsNothing);

    final theme = EveryTheme.resolve(DesignLanguage.material, Brightness.light);
    Color? color(String rel) =>
        tester.widget<Text>(find.descendant(of: row(rel), matching: find.text(rel.split('/').last))).style?.color;
    expect(color('debug.log'), theme.textMuted.withValues(alpha: 0.6));
    expect(color('build'), theme.textMuted.withValues(alpha: 0.6));
    expect(color('README.md'), theme.text);

    await tester.tap(row('lib'));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('files.mark.a.dart'))).data, 'M');
    expect(tester.widget<Text>(find.byKey(const ValueKey('files.mark.new.dart'))).data, 'A');
    expect(find.byKey(const ValueKey('files.mark.b.dart')), findsNothing);

    // Inside an ignored folder everything is dimmed.
    await tester.tap(row('build'));
    await tester.pump();
    expect(color('build/out.txt'), theme.textMuted.withValues(alpha: 0.6));

    await tester.tap(row('many'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('5 more not shown'), 400);
    expect(find.text('5 more not shown'), findsOneWidget);
    // The expanded folders are the session's: a fresh view opens them again.
    expect(container.read(filesEditorProvider('s1')).expanded, {path('lib'), path('build'), path('many')});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an opened file is highlighted; ⌘S saves it through the session; Mention puts @path in the composer', (
    tester,
  ) async {
    await setUpRepo(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(
          Column(
            children: [
              Expanded(child: FilesView(session: info)),
              CodeComposer(
                sessionId: 's1',
                busy: false,
                mode: AgentMode.ask,
                onModeChanged: (_) {},
                onSend: (_, _) {},
                autofocus: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => container.read(filesEditorProvider('s1').notifier).open(path('lib/a.dart')));
    await tester.pump();

    final field = tester.widget<EditableText>(
      find.descendant(of: find.byKey(const ValueKey('files.text')), matching: find.byType(EditableText)),
    );
    expect(field.controller.text, 'void main() {\n  print(2);\n}\n');
    final span = field.controller.buildTextSpan(
      context: tester.element(find.byKey(const ValueKey('files.text'))),
      withComposing: false,
    );
    final colors = <Color?>{};
    void collect(InlineSpan s) {
      colors.add(s.style?.color);
      if (s is TextSpan) s.children?.forEach(collect);
    }

    collect(span);
    expect(colors.length, greaterThan(1), reason: 'keywords and numbers get their own colours');

    await tester.enterText(find.byKey(const ValueKey('files.text')), 'void main() {}\n');
    await tester.pump();
    expect(find.byKey(const ValueKey('files.dirty')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await _when(container, filesEditorProvider('s1').select((b) => b.dirty), (bool d) => !d);
    });
    await tester.pump();
    expect(File(path('lib/a.dart')).readAsStringSync(), 'void main() {}\n');
    expect(find.byKey(const ValueKey('files.dirty')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('files.mention')));
    await tester.pump();
    expect(container.read(composerInsertProvider('s1'))?.text, '@lib/a.dart ');
    final composer = tester.widget<EditableText>(
      find.descendant(of: find.byType(CodeComposer), matching: find.byType(EditableText)),
    );
    expect(composer.controller.text, '@lib/a.dart ');
    // At the caret, with a space after what was typed.
    composer.controller.value = const TextEditingValue(
      text: 'look at and fix',
      selection: TextSelection.collapsed(offset: 7),
    );
    await tester.tap(find.byKey(const ValueKey('files.mention')));
    await tester.pump();
    expect(composer.controller.text, 'look at @lib/a.dart  and fix');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unsaved edit survives switching the panel away and back; opening another file asks first', (
    tester,
  ) async {
    await setUpRepo(tester);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container.read(consolePanelProvider('s1').notifier).show(ConsoleView.files);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(ConsolePanelView(session: info)),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => container.read(filesEditorProvider('s1').notifier).open(path('README.md')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('files.text')), '# Draft\n');
    await tester.pump();

    container.read(consolePanelProvider('s1').notifier).show(ConsoleView.info);
    await tester.pump();
    expect(find.byKey(const ValueKey('files.text')), findsNothing);
    container.read(consolePanelProvider('s1').notifier).show(ConsoleView.files);
    await tester.pump();
    await tester.pump();
    expect(find.text('# Draft\n'), findsOneWidget);
    expect(find.byKey(const ValueKey('files.dirty')), findsOneWidget);

    await tester.tap(row('.gitignore'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes to README.md?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(filesEditorProvider('s1')).path, path('README.md'));
    expect(container.read(filesEditorProvider('s1')).text, '# Draft\n');
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test('Open in text editor never hands a file to the system to run', () {
    List<String>? cmd(String path, String os, {bool executable = false}) =>
        switch (textOpenCommand(path, os: os, executable: executable)) {
          final c? => [c.exe, ...c.args],
          null => null,
        };
    for (final f in ['setup.command', 'build.bat', 'tool.js', 'x.vbs', 'setup.exe', 'a.ps1', 'run.sh', 'README.md']) {
      expect(cmd('/r/$f', 'macos', executable: true), ['open', '-t', '/r/$f']);
      expect(cmd('C:\\r\\$f', 'windows'), ['notepad.exe', 'C:\\r\\$f']);
    }
    expect(cmd('/r/run.sh', 'linux', executable: true), isNull);
    expect(cmd('/r/app.desktop', 'linux'), isNull);
    expect(cmd('/r/README.md', 'linux'), ['xdg-open', '/r/README.md']);
    expect(cmd('/r/README.md', 'android'), isNull);
  });

  testWidgets("a file the view can't show has no Open in text editor", (tester) async {
    await setUpRepo(tester);
    await tester.runAsync(() => File(path('logo.bin')).writeAsBytes([0x89, 0, 1, 2]));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(FilesView(session: info)),
      ),
    );
    await tester.runAsync(() => container.read(filesEditorProvider('s1').notifier).open(path('logo.bin')));
    await tester.pump();
    expect(find.text('Not a text file.'), findsOneWidget);
    expect(find.byKey(const ValueKey('files.external')), findsNothing);
    await tester.runAsync(() => container.read(filesEditorProvider('s1').notifier).open(path('README.md')));
    await tester.pump();
    expect(find.byKey(const ValueKey('files.external')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a file changed while the view was away shows the disk; an edited one is marked as a conflict', (
    tester,
  ) async {
    await setUpRepo(tester);
    final editor = container.read(filesEditorProvider('s1').notifier);
    await tester.runAsync(() => editor.open(path('README.md')));
    // The agent rewrote it with no Files view on screen; the diff refreshed.
    await tester.runAsync(() async {
      File(path('README.md')).writeAsStringSync('# By the agent\n');
      await container.read(codeGitProvider('s1').notifier).refresh();
      await _when(container, filesEditorProvider('s1'), (FilesBuffer b) => b.opened == '# By the agent\n');
    });
    expect((editor.state.text, editor.state.dirty, editor.state.conflict), ('# By the agent\n', false, false));

    editor.edit('# Mine\n');
    await tester.runAsync(() async {
      File(path('README.md')).writeAsStringSync('# Agent again\n');
      await container.read(codeGitProvider('s1').notifier).refresh();
      await _when(container, filesEditorProvider('s1'), (FilesBuffer b) => b.conflict);
    });
    expect((editor.state.text, editor.state.opened), ('# Mine\n', '# By the agent\n'));
  });

  testWidgets("a save that returns after the file was closed doesn't touch what is open now", (tester) async {
    await setUpRepo(tester);
    final editor = container.read(filesEditorProvider('s1').notifier);
    await tester.runAsync(() async {
      await editor.open(path('README.md'));
      editor.edit('# Saved\n');
      final saving = editor.save();
      editor.close();
      await saving;
    });
    expect(File(path('README.md')).readAsStringSync(), '# Saved\n');
    expect((editor.state.path, editor.state.opened, editor.state.dirty), (null, null, false));
  });

  testWidgets('a minified one-line file opens as plain text', (tester) async {
    await tester.pumpWidget(_app(const SizedBox(key: ValueKey('host'))));
    final context = tester.element(find.byKey(const ValueKey('host')));
    int spans(String text) {
      var n = 0;
      void count(InlineSpan s) {
        n++;
        if (s is TextSpan) s.children?.forEach(count);
      }

      count(FilesCodeController(text: text, language: 'json').buildTextSpan(context: context, withComposing: false));
      return n;
    }

    final row = '{"k": 1, "v": [true, null, "x"]}';
    expect(spans(row), greaterThan(1));
    expect(spans('[${List.filled(3000, row).join(',')}]'), 1);
    expect(spans(List.filled(FilesCodeController.maxChars ~/ row.length + 1, row).join('\n')), 1);
  });

  testWidgets('discarding after the view went away still opens the file', (tester) async {
    await setUpRepo(tester, overrides: [filesEditorProvider.overrideWith2(_NoDiskEditor.new)]);
    final showing = ValueNotifier(true);
    addTearDown(showing.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(
          ValueListenableBuilder(
            valueListenable: showing,
            builder: (context, on, _) => on ? FilesView(session: info) : const SizedBox(),
          ),
        ),
      ),
    );
    await container.read(filesEditorProvider('s1').notifier).open(path('README.md'));
    container.read(filesEditorProvider('s1').notifier).edit('# Draft\n');
    await tester.pump();
    await tester.tap(row('.gitignore'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes to README.md?'), findsOneWidget);
    // An approval closed the narrow panel meanwhile.
    showing.value = false;
    await tester.pump();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(container.read(filesEditorProvider('s1')).path, path('.gitignore'));
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  group('bottom drawer', () {
    testWidgets('⌃` toggles it with the composer focused; a drag sets its height, remembered per session', (
      tester,
    ) async {
      final prefs = Preferences.inMemory();
      final session = CodeSessionInfo(
        id: 'd1',
        projectId: 'p1',
        title: 'Drawer',
        conversationId: 'c',
        model: 'm',
        mode: AgentMode.ask,
        workingDir: '/tmp/drawer',
        createdAt: DateTime(2026),
      );
      final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: _app(
            BottomDrawer(
              session: session,
              paneBuilder: (p) => Text('pane ${p.name}'),
              child: const Align(
                alignment: Alignment.bottomCenter,
                child: m.TextField(key: ValueKey('composer'), autofocus: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('drawer')), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('pane terminal'), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('drawer'))).height, BottomDrawer.defaultHeight);

      await tester.drag(find.byKey(const ValueKey('drawer.handle')), const Offset(0, -100), touchSlopY: 0);
      await tester.pump();
      expect(tester.getSize(find.byKey(const ValueKey('drawer'))).height, BottomDrawer.defaultHeight + 100);
      expect(c.read(codePaneProvider('d1')).height, BottomDrawer.defaultHeight + 100);
      // Never taller than 70% of the column.
      await tester.drag(find.byKey(const ValueKey('drawer.handle')), const Offset(0, -2000), touchSlopY: 0);
      await tester.pump();
      expect(tester.getSize(find.byKey(const ValueKey('drawer'))).height, closeTo(800 * 0.7, 0.01));

      await tester.tap(find.byKey(const ValueKey('drawer.tab.preview')));
      await tester.pump();
      expect(find.text('pane preview'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byKey(const ValueKey('drawer')), findsNothing);

      final again = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      addTearDown(again.dispose);
      again.read(codePaneProvider('d1').notifier).toggleDrawer();
      expect(again.read(codePaneProvider('d1')).open, CodePane.preview);
      expect(again.read(codePaneProvider('d1')).height, closeTo(800 * 0.7, 0.5));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('closing from a focused terminal keeps ⌃` working to open it again', (tester) async {
      final session = CodeSessionInfo(
        id: 'd2',
        projectId: 'p1',
        title: 'Drawer',
        conversationId: 'c',
        model: 'm',
        mode: AgentMode.ask,
        workingDir: '/tmp/drawer',
        createdAt: DateTime(2026),
      );
      final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(Preferences.inMemory())]);
      addTearDown(c.dispose);
      c.read(codePaneProvider('d2').notifier).toggleDrawer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: _app(
            BottomDrawer(
              session: session,
              // Like the terminal: it takes the keyboard and handles ⌃` itself.
              paneBuilder: (p) => Focus(
                autofocus: true,
                onKeyEvent: (_, event) => terminalKeys(event, c.read(codePaneProvider('d2').notifier).toggleDrawer),
                child: Text('pane ${p.name}'),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('pane terminal'), findsOneWidget);
      Future<void> toggle() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await toggle();
      expect(c.read(codePaneProvider('d2')).open, isNull);
      await toggle();
      expect(c.read(codePaneProvider('d2')).open, CodePane.terminal);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a focused terminal hands ⌃` to the drawer instead of the shell', (tester) async {
      var toggled = 0;
      KeyEventResult key(LogicalKeyboardKey k, {bool up = false}) => terminalKeys(
        up
            ? KeyUpEvent(physicalKey: PhysicalKeyboardKey.backquote, logicalKey: k, timeStamp: Duration.zero)
            : KeyDownEvent(physicalKey: PhysicalKeyboardKey.backquote, logicalKey: k, timeStamp: Duration.zero),
        () => toggled++,
      );
      expect(key(LogicalKeyboardKey.backquote), KeyEventResult.ignored);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(key(LogicalKeyboardKey.backquote), KeyEventResult.handled);
      expect(key(LogicalKeyboardKey.backquote, up: true), KeyEventResult.ignored);
      expect(key(LogicalKeyboardKey.keyA), KeyEventResult.ignored);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(toggled, 1);
    });
  });
}
