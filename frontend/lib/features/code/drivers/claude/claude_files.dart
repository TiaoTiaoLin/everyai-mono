// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'claude_files_stub.dart' if (dart.library.io) 'claude_files_io.dart' as impl;

// What the Claude Code driver reads and writes outside the CLI's pipe.

/// [path]'s text, or null when it isn't there.
Future<String?> readTextFile(String path) => impl.readTextFile(path);

/// Writes [text] to [path] whole (the folder is made when missing).
Future<void> writeTextFile(String path, String text) => impl.writeTextFile(path, text);

/// Makes the folder [path] when missing.
Future<void> makeDir(String path) => impl.makeDir(path);

/// What [executable] [args] prints, run with the login shell's environment
/// (10 s at most), or null when it fails to run.
Future<String?> runQuiet(String executable, List<String> args) => impl.runQuiet(executable, args);

/// Whether the CLI still holds session [id] for folder [cwd] (`<config>/projects/<folder name>/<id>.jsonl`;
/// [configDir] replaces `$CLAUDE_CONFIG_DIR` or `~/.claude`). True when it can't tell.
Future<bool> claudeSessionExists(String cwd, String id, {String? configDir}) =>
    impl.claudeSessionExists(cwd, id, configDir: configDir);
