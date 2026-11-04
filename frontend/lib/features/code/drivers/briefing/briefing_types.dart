/// What a driver hands an external coding CLI so it can use EveryAI's tools and skills in one session.
///
/// Local plain types: the core lane's `DriverBriefing` maps onto [BriefingInput] when the pieces are joined.
library;

/// The MCP server name every CLI sees.
const everyaiServerName = 'everyai';

/// The environment variable that carries the session's bearer token. Its own name, because Claude Code blanks
/// credential-looking names (ANTHROPIC_API_KEY, ...) in remote headers.
const tokenEnvVar = 'EVERYAI_MCP_TOKEN';

/// The generated skill every CLI is pointed at.
const sessionSkillName = 'everyai-session';

/// The facts a recipe needs. [skillDir] is `<sessionDir>/briefing/skills` (see `exportSkills`); [sessionSkill] is the
/// text from `sessionSkill(...)`.
typedef BriefingInput = ({Uri mcpUrl, String mcpToken, String skillDir, String sessionSkill});

/// One JSON-RPC call the driver sends after `initialize`.
typedef RpcCall = ({String method, Map<String, Object?> params});

/// How to start one CLI for a session. Pure data: nothing here is written anywhere.
///
/// - [args] go after the executable; [env] is added to its environment (the token lives only here or in a pipe).
/// - [initRequests] are JSON-RPC calls to send once the connection is initialised (Codex skill roots).
/// - [instructions] is text for the CLI's own instructions slot (Codex `developerInstructions`).
/// - [firstPrompt] is text to prepend to the first prompt, for CLIs with no skill route (Gemini, generic ACP).
typedef Delivery = ({
  List<String> args,
  Map<String, String> env,
  List<RpcCall> initRequests,
  String? instructions,
  String? firstPrompt,
});

/// The folder that holds `skills/`: the Claude plugin root.
String briefingRootOf(String skillDir) {
  final trimmed = skillDir.endsWith('/') ? skillDir.substring(0, skillDir.length - 1) : skillDir;
  final cut = trimmed.lastIndexOf('/');
  return cut <= 0 ? trimmed : trimmed.substring(0, cut);
}
