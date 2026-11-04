import 'dart:convert';

import 'briefing_types.dart';

/// How each CLI gets the briefing, as pure data. Nothing writes to `~/.claude`, `~/.codex`, `~/.config/opencode`
/// or `~/.gemini`, and the token never lands in an argument or on disk: it goes through [Delivery.env] or the ACP
/// pipe (an env var is inherited by the CLI's child processes; see [tokenEnvVar]). Flags are recorded with their sources in docs/research/batches/multi-harness/run1/s1.md.

String _bearer(String ref) => 'Bearer $ref';

/// Claude Code (`claude -p --input-format stream-json ...`). The briefing folder is a session-only plugin
/// (`--plugin-dir`), so the skills load for this run only; the session text is appended to the system prompt (no
/// extra model round trip to load it). Skill shell execution is switched off whatever a skill body says.
/// [strictMcp] ignores the user's own MCP servers.
Delivery claudeCode(BriefingInput i, {bool strictMcp = false, bool grantSkillAccess = true}) {
  final mcp = {
    'mcpServers': {
      everyaiServerName: {
        'type': 'http', // without a type Claude reads an entry with a url as stdio
        'url': i.mcpUrl.toString(),
        'headers': {'Authorization': _bearer('\${$tokenEnvVar}')},
      },
    },
  };
  return (
    args: [
      '--plugin-dir',
      briefingRootOf(i.skillDir),
      '--mcp-config',
      jsonEncode(mcp),
      '--append-system-prompt',
      i.sessionText,
      '--settings',
      jsonEncode({'disableSkillShellExecution': true}),
      if (grantSkillAccess) ...['--add-dir', i.skillDir],
      if (strictMcp) '--strict-mcp-config',
    ],
    env: {tokenEnvVar: i.mcpToken},
    initRequests: const [],
    instructions: null,
    firstPrompt: null,
  );
}

/// Codex (`codex app-server`). `-c` sets the MCP server for this process; skill roots can only be added through the
/// app-server request (`skills.config` only enables or disables). `CODEX_HOME` holds `auth.json` and is left alone.
Delivery codex(BriefingInput i) => (
  args: [
    '-c',
    'mcp_servers.$everyaiServerName.url=${jsonEncode(i.mcpUrl.toString())}',
    '-c',
    'mcp_servers.$everyaiServerName.bearer_token_env_var=${jsonEncode(tokenEnvVar)}',
  ],
  env: {tokenEnvVar: i.mcpToken},
  initRequests: [
    (
      method: 'skills/extraRoots/set',
      params: {
        'extraRoots': [i.skillDir],
      },
    ),
  ],
  // Goes in thread/start `developerInstructions`.
  instructions: i.sessionText,
  firstPrompt: null,
);

/// OpenCode (`opencode serve` / `opencode acp`, a process we start). `OPENCODE_CONFIG_CONTENT` outranks project
/// config and writes no file. The server goes under `mcp.servers.<name>`, the shape 2.1.3 documents itself.
Delivery openCode(BriefingInput i) {
  final config = {
    'mcp': {
      'servers': {
        everyaiServerName: {
          'type': 'remote',
          'url': i.mcpUrl.toString(),
          'disabled': false,
          'headers': {'Authorization': _bearer('{env:$tokenEnvVar}')},
        },
      },
    },
    'skills': [i.skillDir],
    'instructions': ['${briefingRootOf(i.skillDir)}/$sessionFileName'],
  };
  return (
    args: const [],
    env: {'OPENCODE_CONFIG_CONTENT': jsonEncode(config), tokenEnvVar: i.mcpToken},
    initRequests: const [],
    instructions: null,
    firstPrompt: null,
  );
}

/// Gemini CLI (`gemini --acp`). It has no session-scoped skill root, so the session text and a list of the exported
/// skills (with readable paths) go in the first prompt. MCP goes through `session/new` ([acpMcpServer]).
Delivery gemini(BriefingInput i, {List<({String name, String description})> skills = const []}) => (
  args: ['--acp', '--include-directories', i.skillDir],
  env: const {},
  initRequests: const [],
  instructions: null,
  firstPrompt: _inlineBriefing(i, skills),
);

/// Any other ACP agent. Same inline briefing; the driver adds [acpMcpServer] to `session/new` when the agent
/// advertises `mcpCapabilities.http`.
Delivery acp(BriefingInput i, {List<({String name, String description})> skills = const []}) => (
  args: const [],
  env: const {},
  initRequests: const [],
  instructions: null,
  firstPrompt: _inlineBriefing(i, skills),
);

/// The `session/new` `mcpServers` entry for an HTTP server (ACP session setup). The token travels in the JSON-RPC
/// pipe only.
Map<String, Object?> acpMcpServer(BriefingInput i) => {
  'type': 'http',
  'name': everyaiServerName,
  'url': i.mcpUrl.toString(),
  'headers': [
    {'name': 'Authorization', 'value': _bearer(i.mcpToken)},
  ],
};

String _inlineBriefing(BriefingInput i, List<({String name, String description})> skills) {
  final b = StringBuffer(i.sessionText);
  if (skills.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Skills')
      ..writeln()
      ..writeln('Read a skill\'s SKILL.md when its description fits the task:')
      ..writeln();
    for (final s in skills) {
      b.writeln('- ${s.name}: ${s.description} (`${i.skillDir}/${s.name}/SKILL.md`)');
    }
  }
  return b.toString();
}
