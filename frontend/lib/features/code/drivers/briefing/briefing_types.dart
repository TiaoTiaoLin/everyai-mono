/// What a driver hands an external coding CLI so it can use EveryAI's tools and skills in one session.
///
/// Local plain types: the core lane's `DriverBriefing` maps onto [BriefingInput] when the pieces are joined.
library;

/// The MCP server name every CLI sees.
const everyaiServerName = 'everyai';

/// The environment variable that carries the session's bearer token. Its own name, because Claude Code blanks
/// credential-looking names (ANTHROPIC_API_KEY, ...) in remote headers. Every process the CLI starts inherits it, so
/// project code the agent runs can read it: the host must bind the token to one session, end it with the session and
/// keep credit-spending tools behind that session's own approvals.
const tokenEnvVar = 'EVERYAI_MCP_TOKEN';

/// The generated session text, next to `skills/` in the briefing folder (outside it, so no CLI lists it as a skill).
const sessionFileName = 'session.md';

/// The facts a recipe needs. [skillDir] is `<sessionDir>/briefing/skills` (see `exportSkills`); [sessionText] is the
/// text from `sessionBriefing(...)`, written once at session start.
typedef BriefingInput = ({Uri mcpUrl, String mcpToken, String skillDir, String sessionText});

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

/// The folder that holds `skills/` and [sessionFileName]: the Claude plugin root.
String briefingRootOf(String skillDir) {
  final trimmed = skillDir.endsWith('/') ? skillDir.substring(0, skillDir.length - 1) : skillDir;
  final cut = trimmed.lastIndexOf('/');
  return cut <= 0 ? trimmed : trimmed.substring(0, cut);
}
