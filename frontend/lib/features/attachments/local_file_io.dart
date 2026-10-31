import 'dart:io';

/// Whether [path] is a regular file (not a folder, a missing path or the
/// root `/` some apps put on the clipboard with copied text).
bool isRegularFile(String path) => FileSystemEntity.typeSync(path) == FileSystemEntityType.file;
