// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'resume_files_stub.dart' if (dart.library.io) 'resume_files_io.dart' as impl;

// What the past-session readers take from the machine, read-only. On the web there is nothing to read.

/// The login shell's environment (the one the CLIs run with).
Future<Map<String, String>> resumeEnv() => impl.resumeEnv();

/// [path]'s text when it is a file of at most [maxBytes], else null.
Future<String?> readSmallFile(String path, {int maxBytes = 32 << 20}) => impl.readSmallFile(path, maxBytes: maxBytes);

/// The files directly in [dir] whose names end with [suffix], or none.
Future<List<String>> filesIn(String dir, {String suffix = ''}) => impl.filesIn(dir, suffix: suffix);

/// Rows of a read-only query on the SQLite file at [path]; null when the file is missing or can't be read.
Future<List<Map<String, Object?>>?> sqliteRows(String path, String sql, [List<Object?> params = const []]) =>
    impl.sqliteRows(path, sql, params);
