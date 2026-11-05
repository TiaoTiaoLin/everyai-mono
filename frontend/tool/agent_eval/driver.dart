import 'dart:async';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';

/// Drives one Code session headlessly the way the app's controller does,
/// standing in for the user: it approves what the mode would ask about,
/// answers question cards with their first options and approves plans.
final class EvalRun {
  EvalRun(this.harness, this.spec, {this.spent, this.maxUsd}) : mode = spec.mode;

  final Harness harness;
  final SessionSpec spec;
  AgentMode mode;

  /// What the session has cost so far, in dollars; checked about every 20 s.
  final Future<double> Function()? spent;

  /// Interrupts the agent once [spent] passes this.
  final double? maxUsd;
  double cost = 0;
  bool overBudget = false;

  final builder = TranscriptBuilder();
  late HarnessSession session;

  /// Prompts the user would have clicked through.
  int userApprovals = 0;
  int autoApprovals = 0;
  int refusals = 0;
  int answered = 0;
  int plansApproved = 0;

  /// `task` calls answered with "not available" (the driver runs no children).
  int subagentsRefused = 0;
  static const _noSubagents = SubagentReport(
    SubagentStatus.notStarted,
    'Subagents are not available in this run. Do this part of the work yourself.',
  );

  String _respondedTo = '';
  final _handled = <String>{};
  bool _awaitingRun = true;
  final _done = Completer<Transcript>();

  Future<Transcript> run({Duration timeout = const Duration(minutes: 10)}) async {
    session = await harness.start(spec);
    final sub = session.events.listen(_onEvent);
    final meter = spent == null ? null : Timer.periodic(const Duration(seconds: 20), (_) => _checkBudget());
    try {
      return await _done.future.timeout(timeout);
    } finally {
      meter?.cancel();
      await sub.cancel();
      if (spent != null) cost = await spent!().catchError((_) => cost);
    }
  }

  Transcript get snapshot => builder.snapshot;

  void _onEvent(HarnessEvent e) {
    builder.add(e);
    final t = builder.snapshot;
    if (t.running) _awaitingRun = false;
    final waiting = [...t.pending, ...t.held];
    if (waiting.isNotEmpty) {
      final key = waiting.map((c) => c.id).join(',');
      if (key == _respondedTo) return;
      _respondedTo = key;
      if (spec.holdClientTools && t.held.isNotEmpty) {
        _replyInCall(t.held.first);
      } else {
        // Plan mode and the safety floor refuse the way the app does; the
        // driver plays the user and approves whatever would ask.
        final verdict = PermissionPolicy(workingDir: spec.workingDir).decideAll(waiting, mode);
        if (verdict != null && !verdict.accept) {
          refusals++;
          unawaited(session.respond(accept: false, reason: verdict.reason).then((_) => session.resume()));
        } else {
          verdict == null ? userApprovals++ : autoApprovals++;
          unawaited(session.respond(accept: true));
        }
      }
      return;
    }
    if (t.running || _awaitingRun) return;
    if (t.openQuestion case final q? when _handled.add(q.key)) {
      answered++;
      _send(
        answersMessage(q.questions, [
          for (final _ in q.questions) const QuestionAnswer(selected: {0}),
        ]),
      );
      return;
    }
    if (t.openSubagents case [final first, ...] when _handled.add(first.key)) {
      subagentsRefused++;
      _send(subagentMessage({for (final s in t.openSubagents) s.step.call.id: _noSubagents}));
      return;
    }
    if (t.openPlan case final p? when _handled.add(p.key)) {
      plansApproved++;
      if (mode == AgentMode.plan) mode = AgentMode.autoEdit;
      _awaitingRun = true;
      unawaited(session.setMode(mode).then((_) => _send(planApprovedMessage)));
      return;
    }
    if (t.status == ExecutionStatus.finished || t.status == ExecutionStatus.idle) {
      if (!_done.isCompleted) _done.complete(t);
    }
    if (t.status == ExecutionStatus.error || t.status == ExecutionStatus.stuck) {
      if (!_done.isCompleted) _done.complete(t);
    }
  }

  /// Answers a held card or plan inside the call, as the app does.
  void _replyInCall(ActionCall call) {
    final String reason;
    if (isTaskCall(call)) {
      subagentsRefused++;
      reason = subagentReason({for (final c in snapshot.held.where(isTaskCall)) c.id: _noSubagents});
    } else if (call.toolName == askUserQuestionTool) {
      answered++;
      final qs = Question.listFrom(call.action);
      reason = answersReason(qs, [
        for (final _ in qs) const QuestionAnswer(selected: {0}),
      ]);
    } else {
      plansApproved++;
      if (mode == AgentMode.plan) mode = AgentMode.autoEdit;
      reason = planApprovedReason;
    }
    _awaitingRun = true;
    unawaited(
      session
          .setMode(mode, holdClientTools: true)
          .then((_) => session.respond(accept: false, reason: reason))
          .then((_) => session.resume()),
    );
  }

  Future<void> _checkBudget() async {
    try {
      cost = await spent!();
    } on Object {
      return;
    }
    if (maxUsd == null || cost <= maxUsd! || overBudget) return;
    overBudget = true;
    await session.interrupt();
    if (!_done.isCompleted) _done.complete(snapshot);
  }

  void _send(String text) {
    _awaitingRun = true;
    final noted = snapshot.notedMode == mode ? text : modeNote(mode, text);
    unawaited(session.send(noted));
  }

  /// A readable dump of the transcript.
  String report() {
    final t = snapshot;
    final out = StringBuffer();
    String cut(String s, [int n = 400]) {
      final one = s.replaceAll('\n', ' ⏎ ');
      return one.length <= n ? one : '${one.substring(0, n)}…';
    }

    for (final item in t.items) {
      switch (item) {
        case UserTurn(:final text, :final mode):
          out.writeln('USER${mode == null ? '' : ' [${mode.label}]'}: ${cut(text, 200)}');
        case AgentText(:final text, :final reasoning):
          if (text.trim().isNotEmpty) out.writeln('AGENT: ${cut(text)}');
          if (text.trim().isEmpty && reasoning.trim().isNotEmpty) out.writeln('THINK: ${cut(reasoning, 160)}');
        case ExploreGroup(:final steps):
          out.writeln('EXPLORED (${exploreSummary(steps)}):');
          for (final s in steps) {
            out.writeln('   · ${cut(stepTitle(s.call), 160)}${s.rejected ? '  [REFUSED]' : ''}');
          }
        case StepItem(:final step):
          final r = step.result;
          out.writeln(
            'STEP: ${cut(stepTitle(step.call), 160)}'
            '${r == null
                ? '  [no result]'
                : step.rejected
                ? '  [REFUSED]'
                : step.failed
                ? '  [FAILED]'
                : ''}',
          );
        case SubagentItem(:final tasks):
          out.writeln('SUBAGENTS: ${tasks.keys.join(', ')}');
        case PlanItem(:final tasks):
          out.writeln('TASKS: ${tasks.map((t) => '${t.title} (${t.status})').join('; ')}');
        case QuestionItem(:final questions, :final answers):
          out.writeln(
            'QUESTIONS (${questions.length}): ${questions.map((q) => q.header.isEmpty ? q.question : q.header).join(' | ')}'
            '${answers == null ? '  [OPEN]' : ''}',
          );
        case PlanProposal(:final title, :final steps, :final verdict):
          out.writeln('PLAN "$title": ${steps.length} steps  [${verdict?.name ?? 'OPEN'}]');
          for (final (i, s) in steps.indexed) {
            out.writeln('   ${i + 1}. ${cut(s.title, 140)}${s.files.isEmpty ? '' : '  (${s.files.join(', ')})'}');
          }
        case FilesDelivered(:final files):
          out.writeln('FILES: ${files.map((f) => f.path).join(', ')}');
        case SecurityAlert(:final severity, :final what, :final stopRun):
          out.writeln('SECURITY ALERT [${severity.name}${stopRun ? ', stopped' : ''}]: ${cut(what)}');
        case NoticeItem(:final message):
          out.writeln('NOTICE: ${cut(message)}');
      }
    }
    out.writeln(
      '-- status ${t.status.name}; user approvals $userApprovals, auto $autoApprovals, refused $refusals, '
      'answered $answered cards, approved $plansApproved plans'
      '${spent == null ? '' : '; cost \$${cost.toStringAsFixed(3)}${overBudget ? ' (over budget, interrupted)' : ''}'}',
    );
    return out.toString();
  }
}
