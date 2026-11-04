// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'session_files.dart';

Future<List<String>> listJsonl(String dir, {bool recursive = false}) async => const [];

Future<CappedLines> readLinesCapped(String path, {required int maxBytes}) async =>
    (lines: const <String>[], cut: false);

Future<String?> firstLine(String path, {int maxBytes = 1 << 20}) async => null;

Stream<String> streamLines(String path) => const Stream.empty();
