// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'codex_files_stub.dart' if (dart.library.io) 'codex_files_io.dart' as impl;

/// The text of the file at [path], or null when there is none.
Future<String?> readText(String path) => impl.readText(path);

/// Replaces the file at [path] with [text], making its folder if needed.
Future<void> writeText(String path, String text) => impl.writeText(path, text);
