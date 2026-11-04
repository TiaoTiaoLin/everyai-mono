// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'session_files.dart';

Future<List<String>> listJsonl(String dir, {bool recursive = false}) async {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  try {
    return [
      await for (final e in d.list(recursive: recursive, followLinks: false))
        if (e is File && e.path.endsWith('.jsonl')) e.path,
    ];
  } on FileSystemException {
    return const [];
  }
}

Future<CappedLines> readLinesCapped(String path, {required int maxBytes}) async {
  final file = File(path);
  try {
    final size = await file.length();
    if (size <= maxBytes) return (lines: _split(await file.readAsBytes()), cut: false);
    final half = maxBytes ~/ 2;
    final raf = await file.open();
    try {
      final head = await raf.read(half);
      await raf.setPosition(size - half);
      final tail = await raf.read(half);
      final h = _split(head)..removeLast(); // the last head line is cut short
      final t = _split(tail)..removeAt(0); // so is the first tail line
      return (lines: [...h, ...t], cut: true);
    } finally {
      await raf.close();
    }
  } on FileSystemException {
    return (lines: const <String>[], cut: false);
  }
}

Future<String?> firstLine(String path, {int maxBytes = 1 << 20}) async {
  try {
    final raf = await File(path).open();
    try {
      final bytes = await raf.read(maxBytes);
      final nl = bytes.indexOf(10);
      if (nl < 0 && bytes.length == maxBytes) return null;
      return utf8.decode(nl < 0 ? bytes : bytes.sublist(0, nl), allowMalformed: true);
    } finally {
      await raf.close();
    }
  } on FileSystemException {
    return null;
  }
}

Stream<String> streamLines(String path) {
  final file = File(path);
  if (!file.existsSync()) return const Stream.empty();
  return file
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .handleError((Object _) {}, test: (e) => e is FileSystemException);
}

List<String> _split(List<int> bytes) => const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
