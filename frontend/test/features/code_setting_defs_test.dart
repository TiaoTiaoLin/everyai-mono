import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/permissions_providers.dart';
import 'package:every_ai/features/code/settings/setting_defs.dart';
import 'package:every_ai/features/code/settings/settings.dart' as files;
import 'package:every_ai/features/code/ui/code_settings_section.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  group('file layers', () {
    final commit = settingDef('commitStyle');
    final attribution = settingDef('attribution');
    final rules = settingDef('instructions');

    test('read typed values, and only what the layer sets', () {
      final raw = <String, Object?>{
        'git': {'commitStyle': 'plain', 'attribution': 'yes'},
        'instructions': 'One rule',
      };
      expect(isSetInFile(commit, raw), isTrue);
      expect(readFileValue(commit, raw), 'plain');
      expect(isSetInFile(attribution, raw), isTrue);
      expect(readFileValue(attribution, raw), isNull, reason: 'not a bool');
      expect(readFileValue(rules, raw), ['One rule']);
      expect(isSetInFile(commit, const {}), isFalse);
      expect(readFileValue(commit, {'git': 'x'}), isNull);
    });

    test('write and clear keep every other key, known or not', () {
      final raw = <String, Object?>{
        'colour': 'violet',
        'git': {'attribution': true, 'signing': 'ssh'},
        'agents': {
          'reviewer': {'description': 'Reviews'},
        },
      };
      final set = writeFileValue(commit, raw, 'conventional');
      expect(set['colour'], 'violet');
      expect(set['agents'], raw['agents']);
      expect(set['git'], {'attribution': true, 'signing': 'ssh', 'commitStyle': 'conventional'});
      expect(raw['git'], {'attribution': true, 'signing': 'ssh'}, reason: 'the input is not changed');
      final cleared = clearFileValue(attribution, clearFileValue(commit, set));
      expect(cleared['git'], {'signing': 'ssh'});
      final bare = clearFileValue(attribution, {
        'git': {'attribution': true},
      });
      expect(bare, isEmpty, reason: 'an emptied parent goes too');
    });

    test('permission rules add once and remove cleanly', () {
      var raw = <String, Object?>{'x': 1};
      raw = addFileRule(raw, 'npm test *', allow: true);
      raw = addFileRule(raw, 'npm test *', allow: true);
      raw = addFileRule(raw, 'git push *', allow: false);
      expect(fileRules(raw).allow, ['npm test *']);
      expect(fileRules(raw).deny, ['git push *']);
      raw = removeFileRule(raw, 'npm test *');
      expect(raw['permissions'], {
        'deny': ['git push *'],
      });
      raw = removeFileRule(raw, 'git push *');
      expect(raw, {'x': 1});
    });

    test('ruleFor writes the PermissionRules syntax', () {
      expect(ruleFor(RuleTool.command, ' npm test * '), 'npm test *');
      expect(ruleFor(RuleTool.edit, 'src/**'), 'Edit(src/**)');
      expect(ruleFor(RuleTool.read, '.env*'), 'Read(.env*)');
      expect(ruleFor(RuleTool.mcp, 'browser_*'), 'Mcp(browser_*)');
      expect(ruleFor(RuleTool.edit, '  '), isNull);
      // The rules it makes match like hand-written ones.
      expect(const PermissionRules(allow: ['Edit(src/**)']).allow, [ruleFor(RuleTool.edit, 'src/**')]);
    });

    test('writeLayer reads, edits and writes atomically, keeping unknown keys', () async {
      final dir = await Directory.systemTemp.createTemp('layer');
      addTearDown(() => dir.delete(recursive: true));
      final path = files.projectLayerPath(dir.path, local: true);
      expect(path, '${dir.path}/.everyai/settings.local.json');
      expect(await files.readLayer(path), isEmpty, reason: 'a missing file is an empty layer');

      await File(path).create(recursive: true);
      await File(path).writeAsString('{"theirs": {"keep": [1, 2]}, "git": {"commitStyle": "plain"}}');
      await files.writeLayer(path, (raw) => writeFileValue(commit, raw, 'auto'));
      final text = await File(path).readAsString();
      expect(text, contains('\n  "theirs": {\n    "keep": [\n'), reason: 'two-space indent');
      final back = jsonDecode(text) as Map<String, Object?>;
      expect(back['theirs'], {
        'keep': [1, 2],
      });
      expect(readFileValue(commit, back), 'auto');
      expect(dir.listSync(recursive: true).where((f) => f.path.endsWith('.tmp')), isEmpty);
      // The merged settings sessions get see it.
      expect((await files.loadAgentSettings(dir.path)).commitStyle.name, 'auto');

      await File(path).writeAsString('[1]');
      expect(() => files.readLayer(path), throwsFormatException);
      expect(() => files.writeLayer(path, (raw) => raw), throwsFormatException);
    });
  });

  group('preference layers', () {
    test('global and project prompts, defaults count as unset', () {
      final prompt = settingDef('prompt');
      final tier = settingDef('tier');
      var s = const StoredCodeSettings();
      expect(isSetInPrefs(prompt, s, null), isFalse);
      s = writePrefsValue(prompt, s, 'p1', 'Use pnpm.');
      expect(isSetInPrefs(prompt, s, 'p1'), isTrue);
      expect(isSetInPrefs(prompt, s, null), isFalse);
      expect(readPrefsValue(prompt, s, 'p1'), 'Use pnpm.');
      s = clearPrefsValue(prompt, s, 'p1');
      expect(s.projectPrompts, isEmpty);

      expect(isSetInPrefs(tier, s, null), isFalse);
      s = writePrefsValue(tier, s, null, HarnessTier.max);
      expect(isSetInPrefs(tier, s, null), isTrue);
      expect(clearPrefsValue(tier, s, null).tier, HarnessTier.efficient);

      final sites = settingDef('researchSites');
      expect(isSetInPrefs(sites, s, null), isFalse);
      s = writePrefsValue(sites, s, null, ['https://Example.com/docs']);
      expect(readPrefsValue(sites, s, null), ['example.com']);
      expect(
        isSetInPrefs(settingDef('autoCompact'), writePrefsValue(settingDef('autoCompact'), s, null, 0), null),
        isTrue,
      );
    });

    test('each scope has its own settings', () {
      expect(defsFor(SettingsScope.global).map((d) => d.key), containsAll(['prompt', 'tier', 'forks', 'permissions']));
      expect(defsFor(SettingsScope.project).map((d) => d.key), isNot(contains('tier')));
      expect(defsFor(SettingsScope.session).map((d) => d.key), ['model', 'effort', 'mode', 'budget']);
    });
  });

  testWidgets('the Code section adds a setting into the global file and keeps the rest', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('global')))!;
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/settings.json';
    await tester.runAsync(() => File(path).writeAsString('{"mine": true}'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences.inMemory()),
          userSettingsPathProvider.overrideWith((ref) async => path),
          // No real CLIs are looked for.
          driverRegistryProvider.overrideWithValue(DriverRegistry(const {})),
        ],
        child: m.MaterialApp(
          builder: (context, child) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
          home: const m.Material(child: CodeSettingsSection()),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('code-settings.row.prompt')), findsOneWidget);
    expect(find.byKey(const ValueKey('code-settings.row.permissions')), findsOneWidget);
    expect(find.byKey(const ValueKey('code-settings.row.commitStyle')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('code-settings.add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Commit style'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('code-settings.row.commitStyle')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('code-settings.row.commitStyle')),
        matching: find.text('Automatic'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plain').last);
    // The write is real file IO: let it finish.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    final back = jsonDecode((await tester.runAsync(() => File(path).readAsString()))!) as Map<String, Object?>;
    expect(back, {
      'mine': true,
      'git': {'commitStyle': 'plain'},
    });

    // A prefs-backed setting goes to Preferences, not the file.
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('code-settings.prompt')), matching: find.byType(EditableText)),
      'Be brief.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('code-settings.prompt.save')));
    await tester.pump();
    final c = ProviderScope.containerOf(tester.element(find.byType(CodeSettingsSection)));
    expect(c.read(codeSettingsProvider).globalPrompt, 'Be brief.');
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });
}
