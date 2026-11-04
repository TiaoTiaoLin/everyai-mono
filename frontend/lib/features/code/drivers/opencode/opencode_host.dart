// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'opencode_host_stub.dart' if (dart.library.io) 'opencode_host_io.dart' as impl;

/// What a one-shot `opencode …` command printed, and how it ended.
typedef CliRun = ({int exitCode, String stdout});

/// Runs `[executable] [args]` in [cwd] with the login shell's environment,
/// for at most 10 s (`opencode auth list`, `opencode api model.list`).
Future<CliRun> runOpenCodeCli(String executable, List<String> args, {String? cwd}) =>
    impl.runOpenCodeCli(executable, args, cwd: cwd);

/// The text of [path], or null when there is none.
Future<String?> readTextFile(String path) => impl.readTextFile(path);

/// Writes [text] to [path] whole (through a temporary file), making folders.
Future<void> writeTextFile(String path, String text) => impl.writeTextFile(path, text);
