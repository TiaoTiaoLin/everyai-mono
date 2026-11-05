import '../harness/events.dart';
import 'shell_readonly.dart';
import 'subagents.dart';

/// How much the agent may do without asking.
enum AgentMode {
  /// Reads are free; every command and edit waits for approval.
  ask('Ask', 'Approve every command and edit'),

  /// File edits go through; commands still wait for approval.
  autoEdit('Auto-edit', 'Edits apply; commands need approval'),

  /// Reads and plans only, then waits for "Start building".
  plan('Plan', 'Read the code and propose a plan first'),

  /// Nothing waits (the worktree keeps the main checkout safe), but the
  /// safety floor and deny rules still hold.
  fullAuto('Full auto', 'Runs commands and edits without asking'),

  /// Every EveryAI check off: no safety floor, no deny rules, no risk prompts. The harness runs as if EveryAI weren't
  /// there (an outside lead gets its own skip-permissions mode). The user confirms before switching to it.
  bypass('Bypass permissions', 'No EveryAI checks: everything runs, nothing asks');

  const AgentMode(this.label, this.description);
  final String label;
  final String description;

  /// The agent-server confirmation policy: every mode, Full auto included,
  /// has the server confirm every action, and the app's permission policy
  /// (`permissions.dart`) answers. That keeps the safety floor and the
  /// user's deny rules in force when nothing asks the user.
  /// [holdClientTools] is kept for callers; it no longer changes anything.
  Map<String, Object?> confirmationPolicy({bool holdClientTools = false}) => const {'kind': 'AlwaysConfirm'};

  /// Whether the app approves [call] on its own in this mode.
  bool autoApproves(ActionCall call) {
    final readOnly = isReadOnly(call);
    return switch (this) {
      fullAuto || bypass => true,
      autoEdit => readOnly || isFileEdit(call) || _isClientTool(call),
      plan => readOnly || _isClientTool(call),
      ask => readOnly || _isClientTool(call),
    };
  }

  /// Plan mode refuses anything that changes the workspace.
  /// MCP tools are not refused: they ask, like in Ask mode (see `PermissionPolicy`).
  bool rejects(ActionCall call) =>
      this == plan && !isReadOnly(call) && !_isClientTool(call) && !isMcpTool(call) && !_isLookup(call);

  /// A command that looks things up without changing the project (`isPlanningShell`).
  static bool _isLookup(ActionCall call) =>
      call.actionKind == 'TerminalAction' && call.action['is_input'] != true && isPlanningShell(call.str('command'));

  static bool _isClientTool(ActionCall call) => isClientTool(call);

  /// Writes and edits of files (either harness's file tools).
  static bool isFileEdit(ActionCall call) =>
      const {'FileEditorAction', 'EditAction', 'WriteFileAction', 'ApplyPatchAction'}.contains(call.actionKind);

  /// Actions that only look: viewing files, listing, searching, planning.
  static bool isReadOnly(ActionCall call) => switch (call.actionKind) {
    'FileEditorAction' => call.str('command') == 'view',
    'ReadFileAction' || 'GlobAction' || 'GrepAction' || 'ListDirectoryAction' => true,
    'TaskTrackerAction' || 'ThinkAction' || 'FinishAction' => true,
    // The EveryAI harness: reading a background shell, waiting on it, stopping
    // one the session started, and reading the web.
    'BashOutputAction' || 'MonitorAction' || 'KillShellAction' || 'WebFetchAction' || 'WebSearchAction' => true,
    // Its own headless browser (own profile) and screenshots of the session's own windows: no files change.
    'BrowserAction' || 'ScreenshotAction' => true,
    // Returns a skill's instructions; the app escapes the inline commands it would run.
    'InvokeSkillAction' => true,
    // run_script: a Deno program with no permissions; its bridge reads project files and the web only.
    'ScriptAction' => true,
    // The project memory: a harness-owned notes file under .everyai/.
    'MemoryAction' => true,
    // is_input sends keys to a running process.
    'TerminalAction' => call.action['is_input'] != true && isReadOnlyShell(call.str('command')),
    _ => false,
  };

  /// Why Plan mode refused an action, phrased so the agent keeps exploring
  /// instead of concluding its tools are broken.
  static const planRefusal =
      'Not run: Plan mode is read-only. Viewing files and read-only commands (cat, ls, rg, grep, find, sed -n, '
      'git status/log/diff/show, gh issue/pr view) still run without approval, so keep exploring with those. Looking '
      'things up (git fetch, git pull --ff-only, curl or wget to stdout, npm view, brew info, --help) runs once the '
      'user approves it. When you know what to change, call present_plan and stop.';

  /// One line sent with every message in this mode, so the mode survives the
  /// agent's context being condensed.
  String get reminder => switch (this) {
    ask => 'Mode: Ask. Edits and non-read-only commands wait for the user to approve them; use your tools.',
    autoEdit => 'Mode: Auto-edit. Edits apply at once; other commands wait for approval. Use your tools.',
    plan => 'Mode: Plan. Read-only: do not edit files or change anything. Explore, then call present_plan and stop.',
    fullAuto => 'Mode: Full auto. Everything runs without approval. Use your tools and finish the task.',
    bypass => 'Mode: Bypass permissions. EveryAI approves everything and checks nothing.',
  };

  /// What the agent is told when a message is sent in this mode (see
  /// [modeNote]). Each note stands alone; the latest one wins.
  String get instructions => switch (this) {
    ask =>
      'Mode: Ask. Use your tools: viewing files and read-only commands run at once; edits and other commands '
          'wait for the user to approve them in the app, so propose them as tool calls rather than describing them. '
          'Restrictions from earlier mode notes no longer apply.',
    autoEdit =>
      'Mode: Auto-edit. File edits apply at once and read-only commands run freely; other commands wait for the '
          "user's approval. Do the work with your tools and verify it. Restrictions from earlier mode notes no "
          'longer apply.',
    plan =>
      'Mode: Plan. Investigate before proposing: view files and run read-only commands (cat, ls, rg, grep, find, '
          'sed -n, git status/log/diff/show); they run without approval. Do not edit files or run commands that change '
          "anything. Ask with ask_user_question when a decision is genuinely the user's. When you understand the "
          'change, call present_plan with concrete steps naming the files involved, then stop and wait.',
    fullAuto =>
      'Mode: Full auto. Every command and edit runs without approval. Do the task end to end: read the code, '
          'make the change, run the tests or build, and fix what fails. Restrictions from earlier mode notes no '
          'longer apply.',
    bypass =>
      'Mode: Bypass permissions. EveryAI approves every command and edit, inside or outside the project, and '
          'checks nothing. Restrictions from earlier mode notes no longer apply.',
  };

  /// The mode note for a subagent's conversation: the same limits, without
  /// the tools only the session's own agent has (questions, plans).
  String get subagentInstructions => switch (this) {
    ask =>
      'Mode: Ask. Viewing files and read-only commands run at once; edits and other commands wait for the user to '
          'approve them in the app. Use your tools.',
    autoEdit =>
      'Mode: Auto-edit. File edits apply at once and read-only commands run freely; other commands wait for the '
          "user's approval. Use your tools.",
    plan =>
      'Mode: Plan (read-only). View files and run read-only commands (cat, ls, rg, grep, find, sed -n, git '
          'status/log/diff/show); do not edit files or run anything that changes the workspace. Put what you find '
          'in your final report.',
    fullAuto => 'Mode: Full auto. Commands and edits run without approval. Use your tools and finish the task.',
    bypass => 'Mode: Bypass permissions. EveryAI approves every command and edit and checks nothing.',
  };
}

/// The tag a user message starts with to tell the agent its mode.
const _noteOpen = '<everyai-mode name="';
const _noteClose = '</everyai-mode>';

/// [text] prefixed with a note on [mode]. With [full] (the first message, or
/// after a mode change) the note carries the whole [AgentMode.instructions];
/// otherwise it is the one-line [AgentMode.reminder]. [from] is the mode the
/// agent was last told, so leaving Plan can say so outright. A [subagent]
/// conversation always gets [AgentMode.subagentInstructions].
String modeNote(AgentMode mode, String text, {bool full = true, AgentMode? from, bool subagent = false}) {
  final body = StringBuffer();
  if (from == AgentMode.plan && mode != AgentMode.plan) {
    body.write('You have left Plan mode: it no longer limits you, and you may edit files and run commands now. ');
  }
  body.write(
    subagent
        ? mode.subagentInstructions
        : full
        ? mode.instructions
        : mode.reminder,
  );
  return '$_noteOpen${mode.name}">$body$_noteClose${text.isEmpty ? '' : '\n\n$text'}';
}

/// Splits a mode note off a user message: the mode (null without a note) and
/// the text the user wrote.
(AgentMode?, String) splitModeNote(String text) {
  if (!text.startsWith(_noteOpen)) return (null, text);
  final nameEnd = text.indexOf('"', _noteOpen.length);
  final end = text.indexOf(_noteClose);
  if (nameEnd < 0 || end < 0) return (null, text);
  final name = text.substring(_noteOpen.length, nameEnd);
  final mode = AgentMode.values.where((m) => m.name == name).firstOrNull;
  return (mode, text.substring(end + _noteClose.length).trimLeft());
}

const _sessionOpen = '<everyai-session>';
const _sessionClose = '</everyai-session>';

/// Splits the briefing block (`<everyai-session>…</everyai-session>`, which ACP agents without a skill route get
/// in front of their first prompt) off a user message: the block's text (null without one) and the rest.
(String?, String) splitSessionBlock(String text) {
  if (!text.startsWith(_sessionOpen)) return (null, text);
  final end = text.indexOf(_sessionClose);
  if (end < 0) return (null, text);
  return (text.substring(_sessionOpen.length, end).trim(), text.substring(end + _sessionClose.length).trimLeft());
}

/// The question-card client tool (see AGENTS.md "Question cards").
const askUserQuestionTool = 'ask_user_question';

/// Registered with `client_tools` when a session starts.
const askUserQuestionSpec = <String, Object?>{
  'name': askUserQuestionTool,
  'description':
      'Ask the user 1-4 multiple-choice questions when a decision is genuinely theirs (scope, design, '
      'trade-offs) and you cannot resolve it from the code. Each question has 2-4 options with a short label '
      'and a one-line description of what choosing it means; list the option you recommend first and end its label '
      'with " (Recommended)". Set multi_select when several answers can apply. The user can also write their own '
      'answer. $_askEndsTurn',
  'parameters': {
    'type': 'object',
    'properties': {
      'questions': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 4,
        'items': {
          'type': 'object',
          'properties': {
            'question': {'type': 'string', 'description': 'The full question, ending with ?'},
            'header': {'type': 'string', 'description': 'A 1-3 word label, e.g. "Database"'},
            'multi_select': {'type': 'boolean'},
            'options': {
              'type': 'array',
              'minItems': 2,
              'maxItems': 4,
              'items': {
                'type': 'object',
                'properties': {
                  'label': {'type': 'string'},
                  'description': {'type': 'string'},
                },
                'required': ['label'],
              },
            },
          },
          'required': ['question', 'options'],
        },
      },
    },
    'required': ['questions'],
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};

/// Plan mode's hand-off: the agent proposes, the user approves or revises.
const presentPlanTool = 'present_plan';

/// The agent's list of finished files; the app shows them as cards and
/// approves the call at once, so the agent never waits on it.
const presentFilesTool = 'present_files';

/// A client tool whose call waits for the user's answer (the others are
/// approved at once and the agent carries on).
bool isHeldTool(ActionCall call) => isClientTool(call) && call.toolName != presentFilesTool;

/// The client tools registered with every session.
const clientTools = {askUserQuestionTool, presentPlanTool, presentFilesTool, taskTool, ...forkTools};

/// A call to one of [clientTools]. An MCP server's tool with the same name
/// is not one: it doesn't get a client tool's free pass.
bool isClientTool(ActionCall call) => !isMcpTool(call) && clientTools.contains(call.toolName);

/// A call to a tool of a user-configured MCP server. These never count as
/// read-only, whatever the server's `readOnlyHint` says: in Ask and Plan
/// they wait for the user unless an `Mcp(…)` allow rule matches, and Full
/// auto runs them.
bool isMcpTool(ActionCall call) => call.actionKind == 'MCPToolAction';

/// What the client tools say happens after the call, by answer path.
const _askEndsTurn = 'After calling this tool, stop and end your turn: the answers arrive as the next user message.';
const _askHeld =
    'The call waits while the user answers in the app; their answers come back as the result of this call. '
    'Read them and carry on with the task.';
const _planEndsTurn =
    'After calling this tool, stop and end your turn: the user either approves (you will be told to build it) or '
    'replies with changes.';
const _planHeld =
    'The call waits while the user reviews the plan in the app. Its result says whether they approved it (then '
    'build it) or what they want changed (then revise the plan and present it again).';

/// The client tools to register with a session. With [held] (see
/// `SessionSpec.holdClientTools`) the user's reply comes back as the call's
/// result; otherwise the agent ends its turn and the reply is a new message.
List<Map<String, Object?>> clientToolSpecs({bool held = false}) => [
  if (held)
    {
      ...askUserQuestionSpec,
      'description': (askUserQuestionSpec['description']! as String).replaceAll(_askEndsTurn, _askHeld),
    }
  else
    askUserQuestionSpec,
  if (held)
    {
      ...presentPlanSpec,
      'description': (presentPlanSpec['description']! as String).replaceAll(_planEndsTurn, _planHeld),
    }
  else
    presentPlanSpec,
  presentFilesSpec,
  taskSpecFor(held: held),
  checkForksSpec,
  answerForkSpec,
  stopForkSpec,
];

const presentFilesSpec = <String, Object?>{
  'name': presentFilesTool,
  'description':
      'Tell the user which files are the result of your work, so the app can show them as cards to open. Call it '
      'once, just before your final message, with only the files the user will want (not every file you touched). '
      'It returns at once; carry on and finish your message.',
  'parameters': {
    'type': 'object',
    'properties': {
      'files': {
        'type': 'array',
        'minItems': 1,
        'items': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Path relative to the working directory, or absolute'},
            'title': {'type': 'string', 'description': 'A short name for the file'},
            'description': {'type': 'string', 'description': 'One line on what it is'},
          },
          'required': ['path'],
        },
      },
    },
    'required': ['files'],
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};

const presentPlanSpec = <String, Object?>{
  'name': presentPlanTool,
  'description':
      'Present your implementation plan to the user for approval, in Plan mode or whenever an approach (such as Max) '
      'asks for a plan, once you have read enough of the code to be specific. Each step says what changes and in which files. $_planEndsTurn',
  'parameters': {
    'type': 'object',
    'properties': {
      'title': {'type': 'string', 'description': 'A short name for the change'},
      'summary': {'type': 'string', 'description': 'One or two sentences on the approach'},
      'steps': {
        'type': 'array',
        'minItems': 1,
        'items': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string', 'description': 'What this step does'},
            'detail': {'type': 'string', 'description': 'How, briefly'},
            'files': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Files created or changed',
            },
          },
          'required': ['title'],
        },
      },
      'risks': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Open questions or things that could go wrong',
      },
      'verification': {'type': 'string', 'description': 'How you will check the change works'},
    },
    'required': ['title', 'steps'],
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};
