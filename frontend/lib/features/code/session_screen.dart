part of 'code_providers.dart';

/// Preferences: the run command the user confirmed for each project folder
/// (`{dir: command}`). A command in a project's settings file runs without a
/// card only when it is this one: a cloned repo may carry that file.
const _runCommandsKey = 'code.run_commands';

/// How many times app_run looks for the app's window or URL, a second apart.
const _appRunLooks = 120;

/// After this many looks app_run also takes a listening port for an answer,
/// and off macOS (no windows to see) it stops waiting.
const _appRunQuiet = 10;

/// The lines of the app's output app_run keeps, and shows.
const _appRunKeep = 200;
const _appRunShow = 40;

/// The app app_run started for a session, and the end of its output.
final class _AppRun {
  _AppRun(this.command, this.process, this.before) {
    _sub = process.lines.listen((line) {
      tail.add(line);
      if (tail.length > _appRunKeep) tail.removeAt(0);
    });
    unawaited(process.exitCode.then((code) => exit = code, onError: (Object _) => exit = -1));
  }

  final String command;
  final DriverProcess process;

  /// The windows on screen before it started: none of them is its.
  final Set<int> before;
  final tail = <String>[];
  int? exit;
  late final StreamSubscription<String> _sub;

  String get shown => tail.length <= _appRunShow ? tail.join('\n') : tail.sublist(tail.length - _appRunShow).join('\n');

  /// The local addresses it printed (not Flutter's VM service or DevTools).
  List<String> get urls => detectLocalUrls(
    [
      for (final l in tail)
        if (!RegExp('VM Service|DevTools|debugger', caseSensitive: false).hasMatch(l)) l,
    ].join('\n'),
  );

  Future<void> close() async {
    await process.close();
    await _sub.cancel();
  }
}

/// The host's screen tools for an outside agent (screenshot, browser,
/// app_run). Mixed into [CodeSessionController].
mixin _SessionScreen on Notifier<CodeSessionState> {
  // From the controller.
  String get sessionId;
  TranscriptBuilder get _builder;
  PermissionPolicy get policy;

  /// EveryAI's checks are off for this session (see CodeSessionController.checksBypassed).
  bool get checksBypassed;

  /// The mode EveryAI's checks decide by.
  AgentMode get checkMode;

  /// Cards the app raised for a host call, by card id: the answers, or null
  /// when the card was given up (a chat message, Stop, the call ended).
  final _localAsks = <String, Completer<List<QuestionAnswer>?>>{};

  /// Other apps' windows the user let this session capture: id and process,
  /// as the window server reuses ids.
  final _screenGrants = <({int id, int pid})>{};

  ScreenBrowser? _screenBrowser;

  /// The last browser call: calls run one after another, as they share one page.
  Future<void> _browserTurn = Future.value();
  _AppRun? _appRun;

  /// app_run's start under way (its card, then the spawn), which a call made
  /// meanwhile waits on instead of starting a second copy.
  Future<({_AppRun? run, String? problem})>? _appStarting;

  /// Goes up when the browser and app close: work begun before ends there.
  var _screenGen = 0;

  /// The app app_run started and is still running, for the Processes pane.
  int? get appRunPid {
    final run = _appRun;
    return run != null && run.exit == null ? run.process.pid : null;
  }

  Future<HostResult> _screenCall(HostCall call, CodeSessionInfo info) async {
    final a = ref.read(screenAccessProvider);
    return switch (call.name) {
      screenshotTool => _screenshot(call, info, a),
      browserTool => _browse(call, info, a),
      _ => _runApp(call, info, a),
    };
  }

  /// Shows a card with [questions] for host call [call]; its answers, or
  /// null when it was given up.
  /// A card unanswered after [limit] is given up too.
  Future<List<QuestionAnswer>?> _askLocally(HostCall call, String id, List<Question> questions, {Duration? limit}) {
    final done = _localAsks[id] = Completer();
    if (limit != null) {
      final timer = Timer(limit, () => _settleLocalAsk(id, null));
      unawaited(done.future.whenComplete(timer.cancel));
    }
    _builder.addLocalQuestion(
      ActionCall(id: id, raw: const {}, toolName: askUserQuestionTool, toolCallId: id, action: const {}),
      questions,
    );
    state = state.copyWith(transcript: _builder.snapshot);
    unawaited(call.ended.then((_) => _settleLocalAsk(id, null)));
    return done.future;
  }

  /// Closes card [id] with [answers] (null: given up).
  void _settleLocalAsk(String id, List<QuestionAnswer>? answers) {
    final done = _localAsks.remove(id);
    if (done == null) return;
    _builder.settleLocal(id, answers ?? const []);
    if (ref.mounted) state = state.copyWith(transcript: _builder.snapshot);
    done.complete(answers);
  }

  /// Gives up every card a host call waits on (a chat message, Stop).
  void _refuseLocalAsks() {
    for (final id in [..._localAsks.keys]) {
      _settleLocalAsk(id, null);
    }
  }

  /// Ends the session's browser and app (Stop, the session closing).
  Future<void> _closeScreen() async {
    _screenGen++;
    _refuseLocalAsks();
    final browser = _screenBrowser, run = _appRun;
    _screenBrowser = null;
    _appRun = null;
    await Future.wait([?browser?.close(), ?run?.close()]);
  }

  HostResult _withImages(HostCall call, ScreenResult r) {
    call.images.addAll(r.images);
    return (text: r.text, isError: r.isError);
  }

  static String _osName(String os) => switch (os) {
    'linux' => 'Linux',
    'windows' => 'Windows',
    'macos' => 'macOS',
    _ => 'this device',
  };

  bool _owns(CodeSessionInfo info) =>
      ownsWorkingDir(info, parent: ref.read(codeSessionsProvider.notifier).byId(info.parentId ?? ''));

  Future<HostResult> _screenshot(HostCall call, CodeSessionInfo info, ScreenAccess a) async {
    if (a.os != 'macos') {
      return (
        text: "Error: desktop screenshots aren't supported on ${_osName(a.os)} yet. For web pages use browser.",
        isError: true,
      );
    }
    final app = (call.args['app'] as String?)?.trim();
    final root = info.workingDir;
    final pids = {
      ...await a.sessionPids(tag: info.id, workingDir: root, ownsDir: _owns(info)),
      if (_appRun case final run? when run.exit == null) ...await a.processTree(run.process.pid),
    };
    final pick = await pickSessionWindow(
      await a.listWindows(),
      pids: pids,
      root: root,
      executableOf: a.executableOf,
      granted: (w) => _screenGrants.contains((id: w.id, pid: w.pid)),
      app: app,
      windowId: (call.args['window_id'] as num?)?.toInt(),
    );
    switch (pick) {
      case OwnWindow(:final window, :final others):
        return _withImages(call, await a.capture(window, root, others));
      // Bypass permissions: no question, the window is captured like the session's own.
      case ForeignWindow(:final window) when checksBypassed:
        return _withImages(call, await a.capture(window, root, 0));
      case ForeignWindow(:final window):
        final title = window.title.isEmpty ? '' : ' — “${window.title}”';
        final answers = await _askLocally(call, 'screen-${call.id}', [
          Question(
            header: 'Screenshot',
            question:
                'The agent wants a screenshot of ${window.owner}$title. This window isn\'t one this session started.',
            options: const [
              QuestionOption('Allow for this session', 'It may capture this window again until the session ends.'),
              QuestionOption("Don't allow", 'The agent is told no.'),
            ],
          ),
        ]);
        final a0 = answers?.firstOrNull;
        if (a0 == null || !a0.selected.contains(0) || a0.other.trim().isNotEmpty) {
          final said = a0 == null || a0.other.trim().isEmpty ? '' : ' They said: ${a0.other.trim()}';
          return (text: "Error: the user didn't allow a screenshot of ${window.owner}.$said", isError: true);
        }
        _screenGrants.add((id: window.id, pid: window.pid));
        return _withImages(call, await a.capture(window, root, 0));
      case NoWindow():
        final named = [
          if (app != null && app.isNotEmpty) ' matching "$app"',
          if (call.args['window_id'] case final num id) ' with id ${id.toInt()}',
        ].join();
        return (
          text:
              'Error: no window$named of an app this session started. Start the app with app_run (or from your '
              'shell, in the background), wait for its window, then try again. For web pages use browser.',
          isError: true,
        );
    }
  }

  Future<HostResult> _browse(HostCall call, CodeSessionInfo info, ScreenAccess a) async {
    if (a.os.isEmpty) return (text: 'Error: the browser works on desktop only.', isError: true);
    final gen = _screenGen;
    final dir = await ref.read(codeSessionsProvider.notifier)._driverDir(sessionId);
    final Future<HostResult> turn = _browserTurn.then((_) async {
      if (gen != _screenGen || !ref.mounted) {
        return (text: 'Error: the session was stopped, and its browser with it.', isError: true);
      }
      final b = _screenBrowser ??= a.browser('$dir/browser');
      return _withImages(call, await b.run(call.args, info.workingDir));
    });
    _browserTurn = turn.then((_) {}, onError: (Object _) {});
    return turn;
  }

  /// The project folder [info] belongs to (where its run command is kept),
  /// or its own folder.
  String _projectDirOf(CodeSessionInfo info) =>
      ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull?.path ?? info.workingDir;

  Map<String, String> get _trustedRuns {
    final raw = ref.read(preferencesProvider)[_runCommandsKey];
    if (raw == null) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map<String, Object?>).entries)
          if (e.value case final String c) e.key: c,
      };
    } on Object {
      return {};
    }
  }

  Future<HostResult> _runApp(HostCall call, CodeSessionInfo info, ScreenAccess a) async {
    if (a.os != 'macos' && a.os != 'linux') {
      return (text: "Error: app_run isn't supported on ${_osName(a.os)} yet.", isError: true);
    }
    if (state.mode == AgentMode.plan) {
      return (
        text: 'Not run: Plan mode runs no commands that may change things. app_run works once the plan is approved.',
        isError: true,
      );
    }
    var gone = false;
    unawaited(call.ended.then((_) => gone = true));
    var run = _appRun;
    // A copy that exited, or one the agent wants restarted, makes way for a new one.
    if (run != null && (run.exit != null || call.args['restart'] == true)) {
      _appRun = null;
      await run.close();
      run = null;
    }
    final reused = run != null;
    if (run == null) {
      final starting = _appStarting ??= _startApp(call, info, a);
      final started = await starting;
      if (identical(_appStarting, starting)) _appStarting = null;
      if (started.problem case final problem?) return (text: problem, isError: true);
      run = started.run!;
    }
    final head = reused
        ? 'The app is already running (`${run.command}`, pid ${run.process.pid}); pass restart: true to start it again.'
        : 'Started `${run.command}` (pid ${run.process.pid}).';
    String output() => run!.tail.isEmpty ? '' : '\nOutput so far:\n${run.shown}';
    final mac = a.os == 'macos';
    // A Flutter app's own ports are its debugger's; its window is what counts.
    final ports = !run.command.contains('flutter run');
    final root = info.workingDir;
    final exe = <int, String>{};
    for (var look = 0; look < _appRunLooks && !gone; look++) {
      if (run.exit case final code?) {
        if (identical(_appRun, run)) _appRun = null;
        return (text: 'Error: `${run.command}` exited with code $code.${output()}', isError: true);
      }
      final tree = await a.processTree(run.process.pid);
      if (mac) {
        // Its windows: its process tree's, or new ones of an app built in the folder (opened with `open`).
        final windows = <ScreenWindow>[];
        for (final w in await a.listWindows()) {
          if (w.width < 40 || w.height < 40) continue;
          if (tree.contains(w.pid) ||
              (!run.before.contains(w.id) && (exe[w.pid] ??= await a.executableOf(w.pid)).startsWith('$root/'))) {
            windows.add(w);
          }
        }
        if (windows.isNotEmpty) {
          return (
            text:
                '$head Windows:\n${[for (final w in windows) '- window_id ${w.id}: ${windowLabel(w)}'].join('\n')}\n'
                'Look at one with screenshot {window_id}.${output()}',
            isError: false,
          );
        }
      }
      if (run.urls case [..., final url]) {
        return (text: '$head It serves $url: open it with browser.${output()}', isError: false);
      }
      if (look >= _appRunQuiet) {
        final listening = ports
            ? {
                for (final p in await a.listening(tree))
                  if (p.local) p.port,
              }
            : const <int>{};
        if (listening.isNotEmpty) {
          final at = [for (final p in listening) 'http://localhost:$p'].join(', ');
          return (
            text: '$head It listens on $at: if one is a web page, open it with browser.${output()}',
            isError: false,
          );
        }
        if (!mac) {
          return (
            text:
                "$head It is running, but app_run can't see app windows on ${_osName(a.os)} yet (nor take screenshots "
                'there), and it printed no local URL. Read its output to tell how it is doing.${output()}',
            isError: false,
          );
        }
      }
      await a.poll();
    }
    return (
      text:
          '$head No window, local URL or listening port after 2 minutes. If it is still building, call app_run again '
          '(it won\'t start a second copy). A program with no window or web page (a command-line tool, a server on '
          'another protocol) can\'t be shown: read its output instead.${output()}',
      isError: false,
    );
  }

  /// Starts app_run's app: the command (asked for when it isn't trusted
  /// yet), checked, then spawned, unless Stop came meanwhile.
  Future<({_AppRun? run, String? problem})> _startApp(HostCall call, CodeSessionInfo info, ScreenAccess a) async {
    const stopped = 'Error: the session was stopped, so the app wasn\'t started.';
    final gen = _screenGen;
    final picked = await _runCommandFor(call, info, a);
    if (picked.problem case final problem?) return (run: null, problem: problem);
    if (gen != _screenGen || !ref.mounted) return (run: null, problem: stopped);
    final command = picked.command!;
    if (hostRunDenial(policy: policy, mode: checkMode, tool: appRunTool, command: command) case final why?) {
      return (run: null, problem: '$why\n(command: $command)');
    }
    final dir = await ref.read(codeSessionsProvider.notifier)._driverDir(sessionId);
    final before = a.os == 'macos' ? {for (final w in await a.listWindows()) w.id} : const <int>{};
    if (gen != _screenGen || !ref.mounted) return (run: null, problem: stopped);
    final DriverProcess process;
    try {
      process = await a.spawn(command: command, cwd: info.workingDir, sessionTag: info.id, logPath: '$dir/app-run.log');
    } on Object catch (e) {
      return (run: null, problem: "Error: couldn't start `$command`: $e");
    }
    if (gen != _screenGen || !ref.mounted) {
      await process.close();
      return (run: null, problem: stopped);
    }
    return (run: _appRun = _AppRun(command, process, before), problem: null);
  }

  /// The command app_run starts: the one the user confirmed for this
  /// project, else what they pick on a card (saved for next time).
  Future<({String? command, String? problem})> _runCommandFor(
    HostCall call,
    CodeSessionInfo info,
    ScreenAccess a,
  ) async {
    final project = _projectDirOf(info);
    final layer = projectLayerPath(project, local: true);
    Map<String, Object?> current;
    try {
      current = await readLayer(layer);
    } on Object {
      current = const {};
    }
    String? clean(Object? c) => c is String && c.trim().isNotEmpty ? c.trim() : null;
    final saved = switch (current[runCommandKey]) {
      {'command': final Object? c} => clean(c),
      _ => null,
    };
    final suggested = clean(call.args['command']);
    final trusted = _trustedRuns[project];
    if (saved != null && saved == trusted && (suggested == null || suggested == saved)) {
      return (command: saved, problem: null);
    }
    String? allowed(String? c) =>
        c != null && hostRunDenial(policy: policy, mode: checkMode, tool: appRunTool, command: c) == null ? c : null;
    final detected = [
      for (final c in await detectRunCommandsIn(info.workingDir, a.os))
        if (allowed(c) != null) c,
    ];
    final options = <QuestionOption>[];
    void offer(String? c, String why) {
      if (c == null || options.any((o) => o.shownLabel == c)) return;
      options.add(QuestionOption(c, why));
    }

    offer(allowed(saved), 'Saved in .everyai/settings.local.json');
    offer(allowed(suggested), 'The agent\'s suggestion');
    for (final (i, c) in detected.indexed) {
      if (options.any((o) => o.shownLabel == c)) continue;
      options.add(QuestionOption(i == 0 ? '$c (Recommended)' : c, 'Found in the project\'s files'));
    }
    final dontRun = options.length;
    options.add(const QuestionOption("Don't run it", 'The agent is told no.'));
    final answers = await _askLocally(call, 'run-${call.id}', limit: a.cardLimit, [
      Question(
        header: 'Run the app',
        question:
            'How should the agent start this project\'s app? The command runs in the session\'s folder now, and '
            'again whenever the agent calls app_run in this project. Pick one or type your own.',
        options: options,
      ),
    ]);
    final answer = answers?.firstOrNull;
    if (answer == null || answer.isEmpty) {
      return (command: null, problem: "Error: the user didn't confirm a run command, so the app wasn't started.");
    }
    final typed = answer.other.trim();
    final pick = answer.selected.firstOrNull;
    if (typed.isEmpty && (pick == null || pick == dontRun || pick >= options.length)) {
      return (command: null, problem: 'Error: the user chose not to run the app.');
    }
    final command = typed.isNotEmpty ? typed : options[pick!].shownLabel.trim();
    final prefs = ref.read(preferencesProvider);
    prefs[_runCommandsKey] = jsonEncode({..._trustedRuns, project: command});
    try {
      await writeLayer(
        layer,
        (c) => {
          ...c,
          runCommandKey: {if (c[runCommandKey] case final Map<String, Object?> run) ...run, 'command': command},
        },
      );
    } on Object {
      // A settings file the user broke by hand stays as it is; the command is still trusted here.
    }
    return (command: command, problem: null);
  }
}
