// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'acp_files_stub.dart' if (dart.library.io) 'acp_files_io.dart' as impl;

// The few file and process reads the ACP driver needs, kept apart so the
// rest builds on the web.

/// The JSON object in [path], or null when it is missing or broken.
Future<Map<String, Object?>?> readJsonFile(String path) => impl.readJsonFile(path);

/// Writes [json] to [path] (via a temporary file), creating its folder.
Future<void> writeJsonFile(String path, Object? json) => impl.writeJsonFile(path, json);

/// The skills exported to [skillDir] (`<name>/SKILL.md` front matter).
Future<List<({String name, String description})>> listSkills(String skillDir) => impl.listSkills(skillDir);

/// [command]'s absolute path on the login shell's PATH, or null.
Future<String?> whichCommand(String command) => impl.whichCommand(command);

/// Whether any of [names] is set (non-empty) in the login environment, or
/// in [env] when given (tests). Only presence is checked.
Future<bool> envHasAny(List<String> names, {Map<String, String>? env}) async {
  final vars = env ?? await impl.loginEnv();
  return names.any((n) => (vars[n] ?? '').trim().isNotEmpty);
}

/// Whether Gemini CLI has credentials: an API key in the login environment
/// or in `~/.gemini/.env` / `~/.env` (by name only), or a sign-in type in `~/.gemini/settings.json`. A cached personal Google
/// sign-in doesn't count (Google stopped serving those on 2026-06-18);
/// with a Cloud project set it may be a Code Assist licence, so it is
/// unknown. Reads files only. [home] and [env] replace the user's (tests).
Future<bool?> geminiSignedIn({String? home, Map<String, String>? env}) => impl.geminiSignedIn(home: home, env: env);

/// Whether OpenCode has at least one provider connected
/// (`opencode auth list --standalone --format json`, no model call).
Future<bool?> openCodeSignedIn(String executable) => impl.openCodeSignedIn(executable);

/// Whether Kiro CLI is signed in (`kiro-cli whoami --format json`, no model
/// call; read by `kiroSignedInFrom` in `acp_agents.dart`).
Future<bool?> kiroSignedIn(String executable) => impl.kiroSignedIn(executable);

/// Whether Cursor CLI has a sign-in in the macOS keychain (the entry's
/// presence only, read by `cursorSignedInFrom` in `acp_agents.dart`); null
/// elsewhere.
Future<bool?> cursorSignedIn() => impl.cursorSignedIn();

/// Why Kiro CLI must not start in [cwd], or null: the project's
/// `.kiro/agents/` (agent configs offered as its modes, which can pre-allow
/// tools and run hooks) or `.kiro/settings/mcp.json`.
Future<String?> kiroWorkspaceProblem(String cwd) => impl.kiroWorkspaceProblem(cwd);

/// Why Gemini CLI must not start in [cwd], or null. It counts as headless
/// under the app, so it trusts the folder and reads its `.gemini/settings.json`
/// and policies; those can allow tools ahead of time or start MCP commands,
/// which would never reach the app's approvals. Its forks read their own
/// [folder] (Qwen Code: `.qwen`), named [label] in the problem.
Future<String?> geminiWorkspaceProblem(String cwd, {String folder = '.gemini', String label = 'Gemini CLI'}) =>
    impl.geminiWorkspaceProblem(cwd, folder: folder, label: label);
