import 'file_tree.dart';

Future<FolderListing> listFolder(String dir, int cap) async => const FolderListing([]);
Future<OpenedFile> openForEdit(String path, String root) async => const OpenedFile.none('Files need the desktop app.');
Future<String?> readText(String path) async => null;
Future<void> writeText(String path, String text) async => throw UnsupportedError('Files need the desktop app.');
Future<bool> insideRoot(String root, String path) async => false;
Future<String?> openAsText(String path) async => 'Files need the desktop app.';
