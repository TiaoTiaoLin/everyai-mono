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

/// Whether Gemini CLI has credentials: an API key in the login environment,
/// or a sign-in type in `~/.gemini/settings.json` with its cached Google
/// sign-in. Reads files only; a token that has gone stale still passes.
/// [home] and [env] replace the user's (tests).
Future<bool?> geminiSignedIn({String? home, Map<String, String>? env}) => impl.geminiSignedIn(home: home, env: env);

/// Whether OpenCode has at least one provider connected
/// (`opencode auth list --standalone --format json`, no model call).
Future<bool?> openCodeSignedIn(String executable) => impl.openCodeSignedIn(executable);
