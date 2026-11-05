import 'dart:convert';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart' show codeProjectsProvider;
import 'package:every_ai/features/code/drivers/lead_skills.dart';
import 'package:every_ai/features/skills/ui/lead_skills_section.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  test('the off list round trips per project and lead, sorted, and empties out', () {
    final prefs = Preferences.inMemory();
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    final ctl = c.read(leadSkillsProvider.notifier);
    ctl.setOff('p1', 'claude-code', 'pdf', off: true);
    ctl.setOff('p1', 'claude-code', 'docx', off: true);
    ctl.setOff('p2', 'claude-code', 'pdf', off: true);
    expect(jsonDecode(prefs[leadSkillsOffKey]!), {
      'p1': {
        'claude-code': ['docx', 'pdf'],
      },
      'p2': {
        'claude-code': ['pdf'],
      },
    });
    expect(ctl.off('p1', 'claude-code'), {'docx', 'pdf'});
    expect(ctl.off('p1', 'codex'), isEmpty);
    expect(ctl.off(null, 'claude-code'), isEmpty);
    ctl.setOff('p2', 'claude-code', 'pdf', off: false);
    expect((jsonDecode(prefs[leadSkillsOffKey]!) as Map).keys, ['p1']);
  });

  test('the names a lead lists are kept sorted, once each', () {
    final prefs = Preferences.inMemory();
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    c.read(leadSkillsProvider.notifier).sawSkills('claude-code', ['review', 'pdf', 'pdf']);
    expect(leadSkillsSeen(prefs, 'claude-code'), ['pdf', 'review']);
    expect(leadSkillsSeen(prefs, 'codex'), isEmpty);
  });

  testWidgets('the settings list shows the cached names with a switch per project', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = Preferences.inMemory({
      'code.projects': jsonEncode([
        {'id': 'p1', 'name': 'Alpha', 'path': '/a'},
        {'id': 'p2', 'name': 'Beta', 'path': '/b'},
      ]),
      leadSkillsSeenKey: jsonEncode({
        'claude-code': ['pdf', 'review'],
      }),
      leadSkillsOffKey: jsonEncode({
        'p1': {
          'claude-code': ['pdf'],
        },
      }),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: const m.Material(child: LeadSkillsSection()),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(LeadSkillsSection)));
    expect(container.read(codeProjectsProvider), hasLength(2));
    expect(find.text('pdf'), findsOneWidget);
    expect(find.text('review'), findsOneWidget);
    final switches = find.byType(m.Switch);
    expect(tester.widgetList<m.Switch>(switches).map((s) => s.value), [false, true]);
    await tester.tap(switches.last);
    await tester.pumpAndSettle();
    expect(leadSkillsOff(prefs, 'p1', 'claude-code'), {'pdf', 'review'});
    expect(leadSkillsOff(prefs, 'p2', 'claude-code'), isEmpty);
  });

  testWidgets('a skill that is off but missing from the CLI\'s list keeps its switch, in the chosen project', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = Preferences.inMemory({
      'code.projects': jsonEncode([
        {'id': 'p1', 'name': 'Alpha', 'path': '/a'},
        {'id': 'p2', 'name': 'Beta', 'path': '/b'},
      ]),
      // The CLI left the skill out of its list because it started with it off.
      leadSkillsSeenKey: jsonEncode({
        'claude-code': ['review'],
      }),
      leadSkillsOffKey: jsonEncode({
        'p2': {
          'claude-code': ['pdf'],
        },
      }),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: const m.Material(child: LeadSkillsSection(projectId: 'p2')),
          ),
        ),
      ),
    );
    expect(find.text('Beta'), findsOneWidget);
    expect(tester.widgetList<m.Switch>(find.byType(m.Switch)).map((s) => s.value), [false, true]);
    await tester.tap(find.byType(m.Switch).first);
    await tester.pumpAndSettle();
    expect(leadSkillsOff(prefs, 'p2', 'claude-code'), isEmpty);
  });
}
