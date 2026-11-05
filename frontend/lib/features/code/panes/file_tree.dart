import 'package:flutter/foundation.dart';

import 'file_tree_stub.dart' if (dart.library.io) 'file_tree_io.dart' as impl;

/// The Files view's disk access: one folder at a time, and the files the user opens and saves. Desktop only (the
/// stub lists nothing).

/// One child of a folder.
@immutable
final class TreeEntry {
  const TreeEntry(this.path, this.name, {required this.dir});

  /// Absolute.
  final String path;
  final String name;

  /// A folder (a symlink is never one: the tree doesn't follow links).
  final bool dir;
}

/// A folder's children, folders first, at most [folderCap] of them; [more] were left out.
@immutable
final class FolderListing {
  const FolderListing(this.entries, {this.more = 0});
  final List<TreeEntry> entries;
  final int more;
}

/// The most children one folder shows, so a huge folder (node_modules) stays cheap to draw. The folder is still
/// listed and sorted whole; it is listed again only when it is opened or a file in the diff is added or removed.
const folderCap = 500;

/// The largest file the editor opens.
const editableBytes = 512 * 1024;

Future<FolderListing> listFolder(String dir, {int cap = folderCap}) => impl.listFolder(dir, cap);

/// A file opened in the Files view: its [text], or null with [note] saying why it can't be shown.
@immutable
final class OpenedFile {
  const OpenedFile.text(String this.text) : note = null;
  const OpenedFile.none(String this.note) : text = null;
  final String? text;
  final String? note;
}

/// Reads [path] for the editor: refused over [editableBytes], when it isn't UTF-8 text, or when it (a symlink)
/// leads outside [root].
Future<OpenedFile> openForEdit(String path, {required String root}) => impl.openForEdit(path, root);

/// The text in [path], or null when it is missing or not UTF-8.
Future<String?> readText(String path) => impl.readText(path);

/// Writes [text] into [path] in place (its mode and inode stay).
Future<void> writeText(String path, String text) => impl.writeText(path, text);

/// Whether [path], symlinks resolved, is inside [root] (or would be, for a new file).
Future<bool> insideRoot(String root, String path) => impl.insideRoot(root, path);

/// Opens [path] in the system's text editor, never as a program; returns why it didn't, or null.
Future<String?> openAsText(String path) => impl.openAsText(path);

/// The command that shows [path] as text on [os] (`Platform.operatingSystem`), or null when there is no safe one:
/// macOS `open -t` (the default text editor), Notepad on Windows (the shell's default handler runs scripts and
/// programs), and `xdg-open` on Linux except for [executable] files and `.desktop` launchers, which it would run.
({String exe, List<String> args})? textOpenCommand(String path, {required String os, required bool executable}) =>
    switch (os) {
      'macos' => (exe: 'open', args: ['-t', path]),
      'windows' => (exe: 'notepad.exe', args: [path]),
      'linux' when !executable && !path.toLowerCase().endsWith('.desktop') => (exe: 'xdg-open', args: [path]),
      _ => null,
    };
