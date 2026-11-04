import '../../domain/agent_mode.dart';
import 'briefing_types.dart';

/// A tool our host offers over MCP, and when the agent should reach for it. Supplied by the host lane, so no tool
/// name is fixed here.
typedef HostToolInfo = ({String name, String when});

/// A connected harness, by name and model.
typedef RosterEntry = ({String name, String model});

/// Everything the session skill says. Only [worktree], [projectRoot], the roster and the profiles vary per session.
class SessionSkillInput {
  const SessionSkillInput({
    required this.worktree,
    required this.projectRoot,
    required this.lead,
    this.others = const [],
    this.hostTools = const [],
    this.runtimeProfiles = const [],
  });

  final String worktree;
  final String projectRoot;
  final RosterEntry lead;
  final List<RosterEntry> others;
  final List<HostToolInfo> hostTools;

  /// One line each: how to build, test and run this project. None are recorded yet.
  final List<String> runtimeProfiles;
}

/// The text of the `everyai-session` skill. Pure and deterministic (no timestamps): constant sections first, the
/// per-session ones last, so the start of the text stays the same between sessions.
///
/// It does not state the current mode: a file written once goes stale at the first switch. The per-turn
/// `modeNote(...)` stays the only source; this lists every mode and says the latest note wins.
String sessionSkill(SessionSkillInput input) {
  final b = StringBuffer()
    ..writeln('---')
    ..writeln('name: $sessionSkillName')
    ..writeln(
      'description: "Read first in an EveryAI session: where the workspace is, what each mode allows, which '
      'everyai tools the host offers and when to use them, and how to check your work."',
    )
    ..writeln('---')
    ..writeln()
    ..writeln('# EveryAI session')
    ..writeln()
    ..writeln('You are running inside EveryAI, a desktop app that hosts coding agents. The user watches your work in')
    ..writeln('the app and can answer questions, approve plans and see the files you change there.')
    ..writeln()
    ..writeln('## Workspace')
    ..writeln()
    ..writeln('The session works in a git worktree, so the main checkout stays safe. EveryAI keeps its own files in')
    ..writeln('`.everyai/` inside the project:')
    ..writeln()
    ..writeln('- `.everyai/plans/`: saved plans, one file each.')
    ..writeln('- `.everyai/memory.md`: notes about this project that later sessions read.')
    ..writeln('- `.everyai/spill/`: long command output saved to a file; read the part you need instead of all of it.')
    ..writeln('- `.everyai/uploads/`: files the user attached.')
    ..writeln('- `.everyai/scratch/`: throwaway files. Git ignores it.')
    ..writeln('- `.everyai/commands/` and `.everyai/agents/`: the project\'s own slash commands and agent roles.')
    ..writeln()
    ..writeln('Edit files in the worktree only. Do not edit the project root directly.')
    ..writeln()
    ..writeln('- Worktree (your working directory): `${input.worktree}`')
    ..writeln('- Project root: `${input.projectRoot}`')
    ..writeln()
    ..writeln('## Modes')
    ..writeln()
    ..writeln('The user switches modes in the app. The app puts an `<everyai-mode name="...">` tag at the start of a')
    ..writeln('user message. The latest tag you have seen decides what you may do; it overrides this file.')
    ..writeln();
  for (final m in AgentMode.values) {
    b.writeln('- `${m.name}`: ${m.reminder}');
  }
  b
    ..writeln()
    ..writeln('If a tool call is refused, read the reason and change your approach. Do not repeat the same call.')
    ..writeln()
    ..writeln('## everyai tools')
    ..writeln()
    ..writeln('The host offers these tools through the MCP server named `$everyaiServerName`:')
    ..writeln();
  if (input.hostTools.isEmpty) {
    b.writeln('- None are connected in this session.');
  } else {
    for (final t in input.hostTools) {
      b.writeln('- `${t.name}`: ${t.when}');
    }
  }
  b
    ..writeln()
    ..writeln('## Rules')
    ..writeln()
    ..writeln('- Check per part, not per edit. Finish a coherent part of the change, then run the project\'s checks')
    ..writeln('  once for it. Do not run the tests after every small edit, and do not wait on a full suite for a')
    ..writeln('  change that touches one file; run the nearest tests.')
    ..writeln('- Ask the user when a decision is theirs (scope, design, trade-offs) and the code cannot answer it.')
    ..writeln('  Otherwise decide and go on.')
    ..writeln('- Say what you changed and what you did not check when you finish.')
    ..writeln()
    ..writeln('## Who is in this session')
    ..writeln()
    ..writeln('- Lead: ${input.lead.name} (${input.lead.model})');
  if (input.others.isEmpty) {
    b.writeln('- No other agents are connected.');
  } else {
    for (final o in input.others) {
      b.writeln('- ${o.name} (${o.model})');
    }
  }
  b
    ..writeln()
    ..writeln('## Runtime profiles')
    ..writeln();
  if (input.runtimeProfiles.isEmpty) {
    b.writeln('None recorded yet. Find the build and test commands in the project\'s README or config.');
  } else {
    for (final p in input.runtimeProfiles) {
      b.writeln('- $p');
    }
  }
  return b.toString();
}
