// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'session_files_stub.dart' if (dart.library.io) 'session_files_io.dart' as impl;

/// What [readLinesCapped] read: every line, or (when the file is over the cap) the lines of its head and its tail.
typedef CappedLines = ({List<String> lines, bool cut});

/// Paths of the `*.jsonl` files in [dir] ([recursive] walks the subfolders too); none when it doesn't exist.
Future<List<String>> listJsonl(String dir, {bool recursive = false}) => impl.listJsonl(dir, recursive: recursive);

/// The file's lines, or its first and last `maxBytes / 2` bytes' whole lines when it is bigger.
Future<CappedLines> readLinesCapped(String path, {required int maxBytes}) =>
    impl.readLinesCapped(path, maxBytes: maxBytes);

/// The file's first line, read no further than [maxBytes]; null when it can't be read.
Future<String?> firstLine(String path, {int maxBytes = 1 << 20}) => impl.firstLine(path, maxBytes: maxBytes);

/// Every line of the file, streamed.
Stream<String> streamLines(String path) => impl.streamLines(path);
