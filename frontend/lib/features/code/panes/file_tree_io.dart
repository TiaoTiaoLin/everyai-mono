import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'file_tree.dart';

Future<FolderListing> listFolder(String dir, int cap) async {
  final all = <TreeEntry>[];
  try {
    await for (final e in Directory(dir).list(followLinks: false)) {
      final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => e.path);
      if (name == '.git') continue;
      all.add(TreeEntry(e.path, name, dir: e is Directory));
    }
  } on FileSystemException {
    return const FolderListing([]);
  }
  all.sort((a, b) => a.dir != b.dir ? (a.dir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return FolderListing(all.take(cap).toList(), more: math.max(0, all.length - cap));
}

Future<OpenedFile> openForEdit(String path, String root) async {
  try {
    if (!await insideRoot(root, path)) return const OpenedFile.none("This link leads outside the session's folder.");
    final size = await File(path).length();
    if (size > editableBytes) {
      return OpenedFile.none('Too large to open here (${(size / 1024 / 1024).toStringAsFixed(1)} MB).');
    }
    final text = await readText(path);
    return text == null ? const OpenedFile.none('Not a text file.') : OpenedFile.text(text);
  } on FileSystemException catch (e) {
    return OpenedFile.none("Couldn't open it: ${e.osError?.message ?? e.message}");
  }
}

Future<String?> readText(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    // A NUL byte: binary, even when it decodes.
    if (bytes.contains(0)) return null;
    return utf8.decode(bytes);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

Future<void> writeText(String path, String text) => File(path).writeAsString(text, flush: true);

Future<bool> insideRoot(String root, String path) async {
  try {
    final top = await Directory(root).resolveSymbolicLinks();
    final file = File(path);
    final real = await file.exists()
        ? await file.resolveSymbolicLinks()
        : '${await file.parent.resolveSymbolicLinks()}${Platform.pathSeparator}${file.uri.pathSegments.last}';
    return real == top || real.startsWith('$top${Platform.pathSeparator}');
  } on FileSystemException {
    return false;
  }
}
