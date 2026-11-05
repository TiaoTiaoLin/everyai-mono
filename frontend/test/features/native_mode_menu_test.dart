import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart' show claudeModes;
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  final picked = <String>[];
  final bypassed = <bool>[];
  AgentMode? ours;

  Widget host({List<NativeMode>? modes, String? current, bool bypass = false}) => ProviderScope(
    child: m.MaterialApp(
      home: m.Material(
        child: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: CodeComposer(
              busy: false,
              mode: AgentMode.ask,
              onModeChanged: (m) => ours = m,
              onSend: (_, _) {},
              nativeModes: modes,
              nativeMode: current,
              harnessLabel: 'Claude Code',
              onNativeModeChanged: picked.add,
              nativeBypass: bypass,
              onNativeBypass: bypassed.add,
            ),
          ),
        ),
      ),
    ),
  );

  setUp(() {
    picked.clear();
    bypassed.clear();
    ours = null;
  });

  testWidgets("an outside harness's picker shows its own modes; a greyed one says why and can't be picked", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(modes: claudeModes(autoMode: false), current: 'default'));
    expect(find.text('Default'), findsOneWidget);
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code modes'), findsOneWidget);
    for (final label in ['Accept edits', 'Plan mode']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Full auto'), findsNothing);
    // Claude's own Bypass permissions isn't listed; EveryAI's switch sits under the modes.
    expect(find.text('Bypass permissions'), findsNothing);
    expect(find.text('Bypass EveryAI checks'), findsOneWidget);

    await tester.tap(find.text('Accept edits'));
    await tester.pumpAndSettle();
    expect(picked, ['acceptEdits']);
    expect(ours, isNull);
  });

  testWidgets('without native modes the picker is ours', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('Permissions'), findsOneWidget);
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(ours, AgentMode.plan);
    expect(picked, isEmpty);
  });

  testWidgets('the Bypass EveryAI checks switch asks before turning on, leaves the mode, and turns off at once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(modes: claudeModes(autoMode: true), current: 'auto'));
    await tester.tap(find.text('Auto mode'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Bypass EveryAI checks'));
    await tester.tap(find.text('Bypass EveryAI checks'));
    await tester.pumpAndSettle();
    expect(find.text('Bypass permissions?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(bypassed, isEmpty);

    await tester.tap(find.text('Auto mode'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Bypass EveryAI checks'));
    await tester.tap(find.text('Bypass EveryAI checks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bypass permissions').last);
    await tester.pumpAndSettle();
    expect(bypassed, [true]);
    expect(picked, isEmpty, reason: "the lead's mode is left alone");

    await tester.pumpWidget(host(modes: claudeModes(autoMode: true), current: 'auto', bypass: true));
    await tester.tap(find.text('Auto mode'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Bypass EveryAI checks'));
    await tester.tap(find.text('Bypass EveryAI checks'));
    await tester.pumpAndSettle();
    expect(find.text('Bypass permissions?'), findsNothing, reason: 'turning it off needs no confirmation');
    expect(bypassed, [true, false]);
  });
}
