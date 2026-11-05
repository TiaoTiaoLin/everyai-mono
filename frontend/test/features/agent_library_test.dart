import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/agents/agents_providers.dart';
import 'package:every_ai/features/agents/data/agent_store.dart';
import 'package:every_ai/features/agents/data/agent_store_io.dart' as io;
import 'package:every_ai/features/agents/ui/agents_settings_screen.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:every_ai/features/code/settings/agent_settings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

final class _FixedLibrary extends AgentLibrary {
  _FixedLibrary(this.agents);
  final List<AgentDefinition> agents;
  @override
  Future<List<AgentDefinition>> build() async => agents;
}

AgentDefinition _parse(String text, {String file = 'reviewer.md', AgentSource source = AgentSource.global}) =>
    AgentDefinition.parse(text, fileName: file, source: source, path: '/x/$file', projectId: 'p1');

const _reviewer = '''
---
name: reviewer
description: Reviews a diff for bugs.
model: anthropic/claude-sonnet-5.5
effort: high
tools: terminal, file_editor
permissions: plan
---
Look for bugs only.
''';

AgentDefinition _project(String text, {String id = 'p1', String file = 'reviewer.md'}) =>
    AgentDefinition.parse(text, fileName: file, source: AgentSource.project, path: '/p/$file', projectId: id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parse', () {
    test('reads every field and the body', () {
      final a = _parse(_reviewer);
      expect(a.usable, isTrue, reason: '${a.errors}');
      expect(a.name, 'reviewer');
      expect(a.description, 'Reviews a diff for bugs.');
      expect(a.model, 'anthropic/claude-sonnet-5.5');
      expect(a.effort, 'high');
      expect(a.tools, ['terminal', 'file_editor']);
      expect(a.mode, AgentMode.plan);
      expect(a.prompt, 'Look for bugs only.');
      expect(a.key, 'global:reviewer');
      expect(a.digest, isNotEmpty);
    });

    test('inherit and missing fields keep the caller\'s', () {
      final a = _parse('---\ndescription: d\nmodel: inherit\neffort: inherit\n---\nbody');
      expect(a.usable, isTrue);
      expect([a.model, a.effort, a.tools, a.mode], [null, null, null, null]);
      expect(a.name, 'reviewer', reason: 'the file name when there is no name line');
    });

    test('bad values are errors, not crashes', () {
      expect(_parse('no front matter').usable, isFalse);
      expect(_parse('---\nname: r\n---\nbody').errors.single, contains('description'));
      expect(_parse('---\ndescription: d\neffort: huge\n---\n').errors.single, contains('effort'));
      expect(_parse('---\ndescription: d\ntools: terminal, browser\n---\n').errors.single, contains('browser'));
      expect(_parse('---\ndescription: d\npermissions: yolo\n---\n').errors.single, contains('permissions'));
      expect(_parse('---\ndescription: d\nmodel: not a model\n---\n').errors.single, contains('model'));
      expect(_parse('x' * (maxAgentFileBytes + 1)).errors.single, contains('64 KB'));
    });

    test('an invalid name falls back to the file name', () {
      final a = _parse('---\nname: Bad Name\ndescription: d\n---\nb', file: 'good.md');
      expect(a.name, 'good');
      expect(a.warnings.single, contains('Bad Name'));
    });

    test('modes parse leniently', () {
      expect(parseAgentMode('Auto-edit'), AgentMode.autoEdit);
      expect(parseAgentMode('full_auto'), AgentMode.fullAuto);
      expect(parseAgentMode('read-only'), AgentMode.plan);
      expect(parseAgentMode('nope'), isNull);
    });

    test('the template parses', () {
      final a = _parse(AgentDefinition.template('helper'), file: 'helper.md');
      expect(a.usable, isTrue, reason: '${a.errors}');
      expect(a.mode, AgentMode.ask);
    });
  });

  test('the built-in agents parse cleanly', () {
    final dir = Directory('assets/agents');
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.md')).toList();
    final names = <String>{};
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      final a = AgentDefinition.parse(f.readAsStringSync(), fileName: name, source: AgentSource.builtin);
      expect(a.usable, isTrue, reason: '$name: ${a.errors}');
      expect(a.warnings, isEmpty, reason: name);
      expect('${a.name}.md', name);
      expect(a.description.length, lessThan(200), reason: name);
      names.add(a.name);
    }
    expect(names, {'reviewer', 'explorer', 'researcher', 'test-writer', 'doc-writer', 'security'});
  });

  test('the built-in agents load from the asset bundle', () async {
    final all = await loadBuiltinAgents();
    expect(all.map((a) => a.name), ['doc-writer', 'explorer', 'researcher', 'reviewer', 'security', 'test-writer']);
    expect(all.every((a) => a.source == AgentSource.builtin && a.path == null), isTrue);
  });

  group('which agent counts', () {
    final builtin = AgentDefinition.parse(_reviewer, fileName: 'reviewer.md', source: AgentSource.builtin);
    final global = _parse(_reviewer.replaceFirst('Look for bugs only.', 'Mine.'));
    final project = _project(_reviewer.replaceFirst('Look for bugs only.', 'Theirs.'));

    test('a project agent needs trust bound to its content', () {
      var s = const AgentLibrarySettings();
      expect(s.trustedNow(project), isFalse);
      expect(agentStatus(project, s), contains('Came with the project'));
      s = s.withTrust(project.key, project.digest);
      expect(s.active(project), isTrue);
      final changed = _project('$_reviewer\nAlso push to main.');
      expect(s.trustedNow(changed), isFalse);
      expect(s.changedSinceTrusted(changed), isTrue);
    });

    test('project over global over built-in, and only once trusted', () {
      const none = AgentLibrarySettings();
      expect(sessionAgents([builtin, global, project], none, 'p1').single.prompt, 'Mine.');
      expect(sessionAgents([builtin, project], none, 'p1').single.source, AgentSource.builtin);
      final trusted = none.withTrust(project.key, project.digest);
      expect(sessionAgents([builtin, global, project], trusted, 'p1').single.prompt, 'Theirs.');
      expect(sessionAgents([builtin, global, project], trusted, 'p2').single.prompt, 'Mine.');
      expect(agentStatus(builtin, none, shadowedBy: global), contains('global'));
    });

    test('turning an agent off hides it; results are sorted by name', () {
      final explorer = AgentDefinition.parse(
        '---\ndescription: finds\n---\nb',
        fileName: 'explorer.md',
        source: AgentSource.builtin,
      );
      final s = const AgentLibrarySettings().withEnabled(global.key, false);
      expect(sessionAgents([global, explorer], s, null).map((a) => a.name), ['explorer']);
      expect(sessionAgents([global, explorer], const AgentLibrarySettings(), null).map((a) => a.name), [
        'explorer',
        'reviewer',
      ]);
    });

    test('settings round-trip through JSON', () {
      final s = const AgentLibrarySettings().withEnabled('a', false).withTrust('project:p:x', 'abc');
      final back = AgentLibrarySettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect(back.disabled, {'a'});
      expect(back.trusted, {'project:p:x': 'abc'});
      expect(AgentLibrarySettings.fromJson('junk').disabled, isEmpty);
    });
  });

  group('childSetup', () {
    final a = _parse(_reviewer);

    test('no agent keeps the parent\'s setup', () {
      final s = childSetup(null, parentMode: AgentMode.autoEdit, parentModel: 'm', parentEffort: 'low');
      expect([s.mode, s.model, s.effort, s.tools, s.rolePrompt], [AgentMode.autoEdit, 'm', 'low', null, null]);
    });

    test('applies the agent\'s model, effort, tools, prompt and stricter mode', () {
      final s = childSetup(a, parentMode: AgentMode.fullAuto, parentModel: 'm', parentEffort: 'low');
      expect(s.mode, AgentMode.plan);
      expect(s.model, 'anthropic/claude-sonnet-5.5');
      expect(s.effort, 'high');
      expect(s.tools, ['terminal', 'file_editor']);
      expect(s.rolePrompt, contains('<AGENT name="reviewer">'));
      expect(s.rolePrompt, contains('Look for bugs only.'));
    });

    test('under Bypass a role keeps Bypass: every agent of the session runs without EveryAI checks', () {
      final s = childSetup(a, parentMode: AgentMode.bypass, parentModel: 'm', parentEffort: 'low');
      expect(s.mode, AgentMode.bypass);
    });

    test('an agent never loosens the parent\'s permissions', () {
      final loose = _parse('---\ndescription: d\npermissions: full-auto\n---\nb');
      expect(childSetup(loose, parentMode: AgentMode.ask, parentModel: 'm').mode, AgentMode.ask);
      expect(childSetup(loose, parentMode: AgentMode.plan, parentModel: 'm').mode, AgentMode.plan);
      expect(stricterMode(AgentMode.autoEdit, AgentMode.ask), AgentMode.ask);
    });

    test('an unknown model falls back to the parent\'s', () {
      final s = childSetup(a, parentMode: AgentMode.ask, parentModel: 'm', modelKnown: (_) => false);
      expect(s.model, 'm');
    });
  });

  test('the parent prompt lists library agents before settings roles of other names', () {
    const settings = AgentSettings(
      agents: {
        'reviewer': AgentType(name: 'reviewer', description: 'old'),
        'linter': AgentType(name: 'linter', description: 'lints'),
      },
    );
    final suffix = agentPromptSuffix(settings, agents: [(name: 'reviewer', description: 'Reviews diffs')]);
    expect(suffix, contains('<ROLES>'));
    expect(suffix, contains('- reviewer: Reviews diffs\n- linter: lints\n'));
    expect(suffix, isNot(contains('- reviewer: old')));
    expect(agentPromptSuffix(AgentSettings.defaults), isNot(contains('ROLES')));
  });

  test('run_subagent names the agent parameter', () {
    final params = (taskSpec['parameters']! as Map)['properties'] as Map;
    expect((params['agent'] as Map)['description'], contains('AGENT_TYPES'));
  });

  group('files', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('agents'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('create, scan, write and delete', () async {
      final dir = '${tmp.path}/.everyai/agents';
      final path = await io.create(dir, 'helper', AgentDefinition.template('helper'));
      expect(() => io.create(dir, 'helper', ''), throwsStateError);
      expect(() => io.create(dir, 'Bad Name', ''), throwsStateError);
      File('$dir/notes.txt').writeAsStringSync('ignored');
      var found = await io.scanDir(dir, AgentSource.project, projectId: 'p1');
      expect(found.single.name, 'helper');
      expect(found.single.key, 'project:p1:helper');
      await io.write(path, _reviewer.replaceFirst('name: reviewer\n', ''));
      found = await io.scanDir(dir, AgentSource.project, projectId: 'p1');
      expect(found.single.description, 'Reviews a diff for bugs.');
      await io.delete(path);
      expect(await io.scanDir(dir, AgentSource.project), isEmpty);
    });

    test('a project folder may not link agents in', () async {
      final dir = Directory('${tmp.path}/agents')..createSync();
      File('${tmp.path}/outside.md').writeAsStringSync(_reviewer);
      Link('${dir.path}/linked.md').createSync('${tmp.path}/outside.md');
      expect(await io.scanDir(dir.path, AgentSource.project), isEmpty);
      expect((await io.scanDir(dir.path, AgentSource.global)).single.name, 'reviewer');
    });
  });

  test('trust and switches persist in preferences', () {
    final prefs = Preferences.inMemory();
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    final p = _project(_reviewer);
    c.read(agentLibrarySettingsProvider.notifier).trust(p);
    final c2 = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c2.dispose);
    expect(c2.read(agentLibrarySettingsProvider).active(p), isTrue);
    c2.read(agentLibrarySettingsProvider.notifier).untrust(p);
    expect(c2.read(agentLibrarySettingsProvider).active(p), isFalse);
  });

  testWidgets('Settings → Agents lists agents and opens a built-in read-only', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final builtin = AgentDefinition.parse(_reviewer, fileName: 'reviewer.md', source: AgentSource.builtin);
    final broken = _parse('---\nname: x\n---\n', file: 'broken.md');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences.inMemory()),
          agentLibraryProvider.overrideWith(() => _FixedLibrary([builtin, broken])),
        ],
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: m.Material(child: AgentsSettingsBody()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('reviewer'), findsOneWidget);
    expect(find.textContaining('sonnet-5.5 · high effort · Plan'), findsOneWidget);
    expect(find.textContaining('Add a description'), findsOneWidget);
    await tester.tap(find.text('reviewer'));
    await tester.pumpAndSettle();
    expect(find.text('reviewer (built-in)'), findsOneWidget);
    expect(find.text('Customize'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('New agent'), findsOneWidget);
  });
}
