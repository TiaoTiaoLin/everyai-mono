// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Layout sweep of the cards and chips with hostile content: words with no break point, long paths and commands,
// long titles and labels, many options. Each is laid out alone, at a wide, a medium and a very narrow width, with
// normal and large text, in every design language, and must never overflow.

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/features/attachments/attachment.dart';
import 'package:every_ai/features/attachments/ui/attachment_tray.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/session_commands.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/ui/session_view.dart' show StatusPill;
import 'package:every_ai/features/code/ui/transcript/approval_card.dart';
import 'package:every_ai/features/code/ui/transcript/aside_card.dart';
import 'package:every_ai/features/code/ui/transcript/plan_card.dart';
import 'package:every_ai/features/code/workflows/ui/workflow_card.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:every_ai/features/questions/ui/question_card.dart';
import 'package:every_ai/features/usage/ui/usage_meter.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_host.dart';

const widths = [1000.0, 520.0, 300.0];
const textScales = [1.0, 1.6];
const languages = [DesignLanguage.cupertino, DesignLanguage.macos, DesignLanguage.material, DesignLanguage.fluent];

/// A word with no break point, a path, a sentence: what real agents and users send.
const word = 'supercalifragilisticexpialidocious_with_no_breaks_at_all_anywhere_in_it';
const path = '/Users/someone/projects/a-very-long-project-name/packages/feature_module/lib/src/deeply/nested/file.dart';
const sentence =
    'This is a long sentence that keeps going well past the width of a narrow window, so it has to wrap or be cut.';

ActionCall _call(String id, Map<String, Object?> action, {String tool = 'bash'}) =>
    HarnessEvent.decode({'kind': 'ActionEvent', 'id': id, 'tool_name': tool, 'action': action}) as ActionCall;

final components = <String, Widget Function()>{
  'Question card': () => QuestionCard(
    questions: [
      for (var i = 0; i < 4; i++)
        Question(
          header: 'Header $word',
          question: '$sentence $word?',
          multiSelect: i.isOdd,
          options: [
            QuestionOption('$word (Recommended)', sentence),
            QuestionOption(path, '$sentence $sentence'),
            const QuestionOption('Short', ''),
          ],
        ),
    ],
    onSubmit: (_) {},
  ),
  'Approval card': () => ApprovalCard(
    pending: [
      _call('a', {'kind': 'TerminalAction', 'command': 'rm -rf $path && echo $word | tee $path.log > /dev/null'}),
      _call('b', {'kind': 'FileEditorAction', 'command': 'create', 'path': path, 'file_text': sentence}),
      _call('c', {'kind': 'TerminalAction', 'command': 'npm test -- --grep "$sentence"'}),
    ],
    mode: AgentMode.ask,
    onAllow: (_) {},
    onDeny: (_) {},
    onMode: (_) {},
    onAllowCall: (_, _) {},
    onDenyCall: (_) {},
  ),
  'Plan card': () => PlanCard(
    plan: PlanProposal(
      _call('p', {
        'kind': 'PresentPlanAction',
        'title': 'Plan: $word',
        'summary': '$sentence $sentence',
        'verification': 'Run $path and $word',
        'steps': [
          {
            'title': word,
            'detail': sentence,
            'files': [path, path],
          },
          '$sentence $word',
        ],
      }, tool: 'present_plan'),
    ),
    open: true,
    onApprove: () {},
    onRevise: (_) {},
  ),
  'Aside card (answer)': () => AsideCard(
    aside: Aside(id: 1, kind: AsideKind.btw, question: '$word $sentence', answer: '$sentence\n\n`$path`\n\n$word'),
    onDismiss: () {},
  ),
  'Aside card (usage)': () => AsideCard(
    aside: Aside(
      id: 2,
      kind: AsideKind.cost,
      answer: 'Current week (all models): 35% used · resets Nov 10 at 7:59pm (America/Toronto)\n$sentence\n$word',
    ),
    onDismiss: () {},
    usage: const UsageTotals(calls: 12, promptTokens: 2400000, completionTokens: 90000, chargedMicros: 1234567),
    contextWindow: 200000,
    modelName: 'Claude $word',
    limitLines: ['This week: 35% used · resets Mon 19:59', sentence, word],
  ),
  'Workflow card': () => WorkflowCard(
    run: WorkflowRun(
      runId: 'r',
      name: 'Ultra $word',
      status: WorkflowStatus.done,
      phases: ['Research $word', 'Implement'],
      agents: [
        WorkflowAgentView(key: 'a', label: 'research:$word', phase: 'Research $word'),
        WorkflowAgentView(key: 'b', label: path, phase: 'Implement', status: WorkflowAgentStatus.done),
      ],
      logs: [(phase: 'Implement', text: '$sentence $path $word')],
      spentMicros: 4200000,
    ),
    onStop: () {},
    onDismiss: () {},
  ),
  'Usage breakdown': () => UsageBreakdown(
    totals: const UsageTotals(calls: 9999, promptTokens: 123456789, completionTokens: 9876543, chargedMicros: 98765432),
    contextWindow: 1000000,
    modelName: 'Model $word',
  ),
  'Attachment chip': () => AttachmentChip(name: '$word$path.pdf', kind: AttachmentKind.pdf, size: 123456789),
  'Status pills': () => Wrap(children: [for (final s in SessionStatus.values) StatusPill(status: s)]),
};

void main() {
  for (final entry in components.entries) {
    for (final language in languages) {
      testWidgets('${entry.key} · ${language.name} never overflows', (tester) async {
        final problems = <String>[];
        for (final width in widths) {
          for (final scale in textScales) {
            problems.addAll(
              await sweepOne(
                tester,
                where: '${entry.key} · ${language.name} · ${width.round()} wide · ×$scale',
                size: Size(width, 2400),
                textScale: scale,
                child: ProviderScope(
                  child: LayoutHost(
                    language: language,
                    // A card in a transcript: full width, any height (the list scrolls).
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: SingleChildScrollView(child: entry.value()),
                    ),
                  ),
                ),
              ),
            );
          }
        }
        for (final p in problems.toSet()) {
          debugPrint('LAYOUT: $p');
        }
        expect(problems.toSet().toList(), isEmpty, reason: problems.toSet().join('\n'));
      });
    }
  }
}
