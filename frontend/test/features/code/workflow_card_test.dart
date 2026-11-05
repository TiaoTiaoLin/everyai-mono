// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/workflows/ui/workflow_card.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_runs.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  testWidgets('a finished workflow card can be dismissed; a running one has no dismiss', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final runs = container.read(workflowRunsProvider('s').notifier);
    runs.put(const WorkflowRun(runId: 'done', name: 'Ultra', status: WorkflowStatus.done));
    runs.put(const WorkflowRun(runId: 'live', name: 'Bug fix'));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: m.MaterialApp(
          home: m.Material(
            child: EveryThemeScope(
              theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
              child: const SingleChildScrollView(child: WorkflowRunsView(sessionId: 's')),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Workflow: Ultra'), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow.dismiss.live')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('workflow.dismiss.done')));
    await tester.pump();
    expect(find.text('Workflow: Ultra'), findsNothing);
    expect(find.text('Workflow: Bug fix'), findsOneWidget);
    // Still listed for Running work.
    expect(container.read(workflowRunsProvider('s')), hasLength(2));
  });
}
