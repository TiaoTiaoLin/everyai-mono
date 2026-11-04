part of 'code_providers.dart';

/// Stands in for the cheap side model (tests); null uses the gateway.
final codeSideModelProvider = Provider<Summarizer?>((ref) => null);

/// The Code session commands that work beside the agent: `/review`, `/goal`,
/// `/commit`, `/pr` and `/learn`. Mixed into [CodeSessionController].
mixin _SessionBuiltins on Notifier<CodeSessionState> {
  // From the controller.
  String get sessionId;
  List<HarnessEvent> get _events;
  HarnessSession? get _harnessSession;

  /// Background subagents still working: their reports will wake the agent.
  bool get _backgroundBusy;
  int get _asideIds;
  set _asideIds(int value);
  void _putAside(Aside aside);
  void dismissAside(int id);
  String _leadLabel(String harness);
  Future<void> send(String text, {List<Attachment> files = const []});

  /// Reviewer subagents running, by aside id.
  final _reviewSubs = <int, ProviderSubscription<CodeSessionState>>{};
  final _reviewOf = <String, int>{};
  bool _judging = false;

  void _disposeBuiltins() {
    for (final s in _reviewSubs.values) {
      s.close();
    }
    _reviewSubs.clear();
  }

  CodeSessionInfo? get _info => ref.read(codeSessionsProvider.notifier).byId(sessionId);

  /// The cheap model for side jobs (the judge, commit messages), billed to
  /// the session; null for the demo, which has no model, and on an outside
  /// lead, where EveryAI spends nothing (commit and PR drafts are then
  /// written without a model).
  Future<Summarizer?> _sideModel(CodeSessionInfo info) async {
    if (_outside(info)) return null;
    final override = ref.read(codeSideModelProvider);
    if (override != null) return override;
    if (isDemoPath(info.workingDir)) return null;
    return gatewaySummarizer(
      baseUrl: gatewayBaseUrl(ref),
      apiKey: await gatewayKey(ref),
      sessionTag: info.id,
      model: asideModel,
      onUnauthorized: (k) => remintGatewayKey(ref, k),
    );
  }

  bool _outside(CodeSessionInfo info) => isOutsideLead(info.harness, info.workingDir);

  Aside _newAside(AsideKind kind, String question) {
    final aside = Aside(id: ++_asideIds, kind: kind, question: question.trim(), busy: true);
    _putAside(aside);
    return aside;
  }

  /// Updates [aside] unless the user dismissed it meanwhile.
  void _settle(Aside aside) {
    if (ref.mounted && state.asides.any((a) => a.id == aside.id)) _putAside(aside);
  }

  // ------------------------------------------------------------------ /review

  /// Starts a read-only reviewer subagent on the session's changes; its
  /// report shows as a card (the agent isn't told unless the user sends it).
  Future<void> review(String focus) async {
    final info = _info;
    if (info == null) return;
    final aside = _newAside(AsideKind.review, focus);
    try {
      final w = info.diffTarget;
      final files = w == null ? const <FileDiff>[] : await GitService.diff(w);
      if (w != null && files.isEmpty) return _settle(aside.failed('There are no changes to review yet.'));
      final child = await ref
          .read(codeSessionsProvider.notifier)
          .startChild(
            parent: info,
            title: focus.trim().isEmpty ? 'Review' : 'Review: ${focus.trim()}',
            brief: reviewBrief(files: files, baseCommit: w?.baseCommit, focus: focus),
            mode: AgentMode.plan,
            callId: 'review-${aside.id}',
          );
      if (!ref.mounted) return;
      final running = aside.withChild(child.id);
      _settle(running);
      _reviewOf[child.id] = aside.id;
      final sub = ref.listen(codeSessionProvider(child.id), (_, next) {
        final outcome = subagentOutcome(next.transcript, error: next.error);
        if (outcome != null) _reviewDone(child.id, outcome);
      }, fireImmediately: true);
      if (_reviewOf.containsKey(child.id)) {
        _reviewSubs[aside.id] = sub;
      } else {
        sub.close();
      }
    } on Object catch (e) {
      _settle(aside.failed("Couldn't start the review: $e"));
    }
  }

  /// A reviewer finished or was stopped: its report goes in its card.
  void _reviewDone(String childId, SubagentReport report) {
    final id = _reviewOf.remove(childId);
    if (id == null) return;
    _reviewSubs.remove(id)?.close();
    final aside = state.asides.where((a) => a.id == id).firstOrNull;
    if (aside == null) return;
    _settle(
      report.status == SubagentStatus.completed ? aside.done(report.text, ready: true) : aside.failed(report.text),
    );
  }

  /// Hands a review's findings to the session's agent.
  Future<void> sendReview(int asideId) async {
    final aside = state.asides.where((a) => a.id == asideId).firstOrNull;
    if (aside == null || aside.answer.isEmpty) return;
    dismissAside(asideId);
    await send(reviewFollowUp(aside.answer));
  }

  // -------------------------------------------------------------------- /goal

  /// Sets a standing objective: after each turn a cheap judge checks it and,
  /// while it isn't met and turns remain, sends the agent back to work. On an
  /// outside lead no EveryAI model judges: the goal is kept for its
  /// goal_check tool, and the start message tells the lead to use it.
  /// Returns why it can't be set, else null.
  Future<String?> setGoal(String objective, {int budget = defaultGoalTurns}) async {
    final info = _info;
    final outside = info != null && _outside(info);
    final goal = Goal(objective: objective.trim(), budget: budget, note: outside ? goalByLeadNote : '');
    state = state.copyWith(goal: goal);
    // The lead hears it now, or after its turn (a message sent while it works waits in the queue).
    if (outside) {
      await send(goalLeadMessage(goal.objective));
      return null;
    }
    final moment = goalMoment(state.transcript, queued: state.queued.isNotEmpty);
    if (moment == GoalMoment.user) {
      state = state.copyWith(
        goal: goal.copyWith(status: GoalStatus.waiting, note: 'The agent is waiting for you first.'),
      );
    } else if (moment != GoalMoment.later) {
      await send(goalStartMessage(goal));
    }
    return null;
  }

  void clearGoal() => state = state.copyWith(clearGoal: true);

  void _pauseGoal(String why) {
    final goal = state.goal;
    if (goal == null || goal.status.settled) return;
    state = state.copyWith(
      goal: goal.copyWith(status: GoalStatus.paused, note: why),
    );
  }

  /// Called on every event: judges the goal when a turn has just ended.
  void _goalTick({required bool turnEnded}) {
    final goal = state.goal;
    if (goal == null || goal.status.settled || _judging) return;
    // An outside lead judges its goal itself (goal_check).
    if (_info case final info? when _outside(info)) return;
    final t = state.transcript;
    if (t.running) {
      if (goal.status == GoalStatus.waiting) state = state.copyWith(goal: goal.copyWith(status: GoalStatus.active));
      return;
    }
    if (!turnEnded) return;
    switch (goalMoment(t, queued: state.queued.isNotEmpty)) {
      case GoalMoment.later:
        return;
      case GoalMoment.user:
        state = state.copyWith(
          goal: goal.copyWith(
            status: GoalStatus.waiting,
            note: 'The agent is waiting for you; the goal carries on after.',
          ),
        );
      case GoalMoment.failed:
        _pauseGoal('The agent stopped with an error. Send a message, or set the goal again, to carry on.');
      case GoalMoment.judge when _backgroundBusy:
        // A background report will start another turn; judge after that.
        return;
      case GoalMoment.judge:
        unawaited(_judgeGoal());
    }
  }

  Future<void> _judgeGoal() async {
    final info = _info;
    final start = state.goal;
    if (info == null || start == null) return;
    _judging = true;
    state = state.copyWith(goal: start.copyWith(status: GoalStatus.checking));
    try {
      final String reply;
      if (_harnessSession case final AsksAside self) {
        // The session's own model judges from its cached history.
        reply = await self.askAside(goalSelfCheck(start.objective));
      } else if (_outside(info)) {
        // The lead moved to an outside harness after the goal was set.
        return _pauseGoal(goalOff(_leadLabel(info.harness)));
      } else {
        final model = await _sideModel(info);
        if (model == null) return _pauseGoal('Goals need a real session: the demo has no model to check with.');
        reply = await model(goalJudgeRequest(record: renderSessionRecord(_events), objective: start.objective));
      }
      if (!ref.mounted) return;
      final goal = state.goal;
      // Cleared or replaced while the judge was reading.
      if (goal == null || goal.objective != start.objective || goal.status != GoalStatus.checking) return;
      final verdict = parseGoalVerdict(reply);
      if (verdict == null) {
        _pauseGoal("The check's answer couldn't be read, so the goal is paused.");
      } else if (verdict.met) {
        state = state.copyWith(
          goal: goal.copyWith(status: GoalStatus.met, note: verdict.reason),
        );
      } else if (goal.left <= 0) {
        state = state.copyWith(
          goal: goal.copyWith(status: GoalStatus.outOfTurns, note: verdict.reason),
        );
      } else if (state.transcript.running || state.queued.isNotEmpty) {
        // The user sent something meanwhile; judge after that turn instead.
        state = state.copyWith(
          goal: goal.copyWith(status: GoalStatus.active, note: verdict.reason),
        );
      } else {
        state = state.copyWith(
          goal: goal.copyWith(used: goal.used + 1, status: GoalStatus.active, note: verdict.reason),
        );
        await send(goalContinueMessage(goal, verdict));
      }
    } on Object catch (e) {
      if (ref.mounted) _pauseGoal('The check failed: $e');
    } finally {
      _judging = false;
    }
  }

  // ------------------------------------------------------------ /commit, /pr

  /// Drafts a commit message for the uncommitted changes, shown in a card
  /// where the user edits it and commits.
  Future<void> draftCommit(String hint) async {
    final info = _info;
    if (info == null) return;
    final aside = _newAside(AsideKind.commit, hint);
    final w = info.worktree;
    if (w == null) {
      return _settle(aside.failed('This session is not in a git worktree, so there is nothing to commit.'));
    }
    try {
      final files = await GitService.uncommittedDiff(w);
      if (files.isEmpty) return _settle(aside.failed('Nothing to commit: every change is committed already.'));
      var message = '';
      try {
        final model = await _sideModel(info);
        if (model != null) {
          message = cleanCommitMessage(await model(commitMessageRequest(files: files, title: info.title, hint: hint)));
        }
      } on Object {
        // The user writes it instead.
      }
      _settle(aside.done(message.isEmpty ? info.title : message, ready: true));
    } on Object catch (e) {
      _settle(aside.failed('$e'));
    }
  }

  /// Commits everything with [message] and closes card [asideId]; returns what to tell the user.
  Future<String> commitDraft(int asideId, String message) async {
    final done = await ref.read(codeGitProvider(sessionId).notifier).commit(message.trim());
    dismissAside(asideId);
    return done ? 'Committed' : 'Nothing to commit';
  }

  /// Drafts a pull request (title and body) when the GitHub CLI is ready,
  /// else shows how to open one by hand.
  Future<void> draftPr(String hint) async {
    final info = _info;
    if (info == null) return;
    final aside = _newAside(AsideKind.pr, hint);
    final w = info.worktree;
    if (w == null) {
      return _settle(
        aside.failed('This session is not in a git worktree, so it has no branch to open a pull request from.'),
      );
    }
    try {
      if (!await GitService.ghReady(w.path)) {
        final remote = await GitService.remoteUrl(w);
        return _settle(aside.done(prInstructions(branch: w.branch, base: w.baseBranch, remoteUrl: remote)));
      }
      final (files, commits) = await (GitService.diff(w), GitService.commitSubjects(w)).wait;
      if (files.isEmpty && commits.isEmpty) {
        return _settle(aside.failed('There are no changes to open a pull request for.'));
      }
      var draft = (title: info.title, body: plainPrBody(commits));
      try {
        final model = await _sideModel(info);
        if (model != null) {
          final reply = await model(prRequest(files: files, commits: commits, title: info.title, hint: hint));
          draft = parsePrDraft(reply, fallbackTitle: info.title);
        }
      } on Object {
        // The user writes it instead.
      }
      _settle(aside.done(draft.title, body: draft.body, ready: true));
    } on Object catch (e) {
      _settle(aside.failed('$e'));
    }
  }

  /// Commits what's left (with the title), pushes the branch and opens the
  /// pull request; returns its URL.
  Future<String> openPr(int asideId, {required String title, required String body}) async {
    final git = ref.read(codeGitProvider(sessionId).notifier);
    await git.commit(title.trim());
    final url = await git.createPr(title: title.trim(), body: body.trim());
    dismissAside(asideId);
    return url;
  }

  // ------------------------------------------------------------------- /learn

  /// Writes a skill from a folder, a web page or this session (see
  /// [parseLearnArgs]) and saves it to the skills library, checked like any
  /// import. A folder that already holds skills is imported as it is.
  Future<void> learn(String args) async {
    final LearnSource source;
    try {
      source = parseLearnArgs(args, isFolder: isFolder, base: _info?.workingDir);
    } on FormatException catch (e) {
      return _settle(_newAside(AsideKind.learn, args.trim()).failed(e.message));
    }
    final aside = _newAside(AsideKind.learn, switch (source) {
      LearnFromUrl(:final url) => url,
      LearnFromFolder(:final path) => path,
      LearnFromConversation() => 'this session',
    });
    final skills = ref.read(installedSkillsProvider.notifier);
    try {
      if (source is LearnFromFolder && await holdsSkills(source.path)) {
        final path = expandHome(source.path);
        final found = await findImportCandidates(
          await folderFiles(path),
          fallbackName: path.split('/').where((s) => s.isNotEmpty).last,
        );
        final ok = [
          for (final c in found)
            if (c.ok) c,
        ];
        if (ok.isEmpty) {
          return _settle(
            aside.failed(found.isEmpty ? 'No skill found there.' : found.first.check.report.errors.join(' ')),
          );
        }
        for (final c in ok) {
          await skills.import(c);
        }
        return _settle(
          aside.done('Imported ${[for (final c in ok) '**${c.dirName}**'].join(', ')} into your skills library.'),
        );
      }
      if (_info case final info? when _outside(info)) return _settle(aside.failed(learnOff(_leadLabel(info.harness))));
      final drafter = ref.read(skillDrafterProvider);
      final skill = switch (source) {
        LearnFromUrl(:final url, :final hint) => await drafter.draftFrom(url: url, hint: hint, session: sessionId),
        LearnFromFolder(:final path, :final hint) => await drafter.draftFrom(
          documents: await _folderDocuments(path),
          hint: hint,
          session: sessionId,
        ),
        LearnFromConversation(:final hint) => await drafter.draftFrom(
          messages: _conversationTurns(),
          hint: hint,
          session: sessionId,
        ),
      };
      final candidate = await skillCandidate(skill);
      if (!candidate.ok) return _settle(aside.failed(candidate.check.report.errors.join(' ')));
      await skills.import(candidate);
      _settle(
        aside.done(
          'Saved **${skill.name}** to your skills library: ${skill.description}\n\n'
          'New sessions can use it. Turn it off or remove it in Settings → Skills.',
        ),
      );
    } on FormatException catch (e) {
      _settle(aside.failed(e.message));
    } on StateError catch (e) {
      _settle(aside.failed(e.message));
    } on Object catch (e) {
      _settle(aside.failed("Couldn't write the skill: $e"));
    }
  }

  static Future<List<LearnDocument>> _folderDocuments(String path) async {
    final docs = await readLearnFolder(path);
    if (docs.isEmpty) throw const FormatException('That folder has no text files to learn from.');
    return docs;
  }

  /// The session's messages and replies (no tool steps), oldest first.
  List<Map<String, String>> _conversationTurns() {
    final turns = [
      for (final item in state.transcript.items)
        if (item is UserTurn && item.text.trim().isNotEmpty)
          {'role': 'user', 'content': item.text.trim()}
        else if (item is AgentText && item.text.trim().isNotEmpty)
          {'role': 'assistant', 'content': item.text.trim()},
    ];
    if (turns.isEmpty) throw const FormatException('There is nothing in this session to learn from yet.');
    return turns;
  }
}
