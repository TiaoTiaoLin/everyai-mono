// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'acp_registry.dart';

String? currentPlatformKey() {
  final cpu = Abi.current().toString().split('_').last;
  return platformKey(Platform.operatingSystem, cpu);
}

Future<void> chmodExecutable(String path) async {
  if (Platform.isWindows) return;
  final r = await Process.run('chmod', ['+x', path]);
  if (r.exitCode != 0) throw InstallError("Couldn't make ${path.split('/').last} runnable: ${r.stderr}".trim());
}

// The download, its checks and the unpacking ported from T3 Code (MIT),
// packages/provider-acp-registry/src/server/AcpRegistrySupport.ts
// `installBinary` and `assertExecutableInRoot`; the archive is read in
// process (package:archive) instead of with tar/unzip, and an entry that
// would leave the folder refuses the whole install instead of being skipped.
Future<String> installBinary({
  required String root,
  required String id,
  required String version,
  required BinaryTarget target,
  required http.Client client,
  required Future<void> Function(String path) makeExecutable,
  required int maxDownload,
  required int maxUnpacked,
}) async {
  final agentDir = '$root/$id';
  final dest = Directory('$agentDir/$version');
  final part = Directory('$agentDir/$version.part');
  if (part.existsSync()) part.deleteSync(recursive: true);
  part.createSync(recursive: true);
  try {
    final suffix = _suffix(target.archive);
    final download = File('${part.path}/download$suffix');
    final res = await client.send(http.Request('GET', Uri.parse(target.archive)));
    if (res.statusCode != 200) throw InstallError('The download failed (HTTP ${res.statusCode}).');
    final sink = download.openWrite();
    final digest = _Digest();
    final hasher = sha256.startChunkedConversion(digest);
    var size = 0;
    try {
      await for (final chunk in res.stream) {
        size += chunk.length;
        if (size > maxDownload) throw InstallError('The download is larger than ${_mb(maxDownload)}.');
        hasher.add(chunk);
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    hasher.close();
    if (target.sha256 case final want? when '${digest.value}' != want) {
      throw InstallError("The download didn't match its checksum, so nothing was installed.");
    }
    final files = Directory('${part.path}/files')..createSync();
    if (suffix.isEmpty) {
      final exe = File('${files.path}/${target.cmd}');
      exe.parent.createSync(recursive: true);
      download.renameSync(exe.path);
    } else {
      final outside = <String>[];
      try {
        await extractFileToDisk(
          download.path,
          files.path,
          maxSize: maxUnpacked,
          callback: (e) {
            if (leavesFolder(e.name, e.symbolicLink)) outside.add(e.name);
          },
        );
      } on ArchiveException catch (e) {
        throw InstallError("Couldn't unpack the download: ${e.message}");
      }
      if (outside.isNotEmpty) {
        throw InstallError('The download has files outside its folder (${outside.first}), so nothing was installed.');
      }
      download.deleteSync();
    }
    final exe = '${files.path}/${target.cmd}';
    final real = FileSystemEntity.typeSync(exe) == FileSystemEntityType.notFound
        ? null
        : File(exe).resolveSymbolicLinksSync();
    final top = files.resolveSymbolicLinksSync();
    if (real == null || !real.startsWith('$top/') || FileSystemEntity.typeSync(real) != FileSystemEntityType.file) {
      throw InstallError("The download didn't contain ${target.cmd}.");
    }
    await makeExecutable(real);
    if (dest.existsSync()) dest.deleteSync(recursive: true);
    files.renameSync(dest.path);
    part.deleteSync(recursive: true);
    // Older versions go once the new one is in place.
    for (final other in Directory(agentDir).listSync()) {
      if (other.path.split('/').last != version) other.deleteSync(recursive: true);
    }
    return '${dest.path}/${target.cmd}';
  } on Object {
    if (part.existsSync()) part.deleteSync(recursive: true);
    rethrow;
  }
}

Future<void> removeAgentFiles(String root, String id) async {
  final dir = Directory('$root/$id');
  if (dir.existsSync()) await dir.delete(recursive: true);
}

/// The file suffix package:archive reads the kind from, or '' for a bare
/// program (T3 Code `archiveKind`).
String _suffix(String url) {
  final path = Uri.parse(url).path.toLowerCase();
  if (path.endsWith('.tar.gz') || path.endsWith('.tgz')) return '.tar.gz';
  if (path.endsWith('.tar.bz2') || path.endsWith('.tbz2') || path.endsWith('.tbz')) return '.tar.bz2';
  if (path.endsWith('.zip')) return '.zip';
  return '';
}

String _mb(int bytes) => '${bytes ~/ (1024 * 1024)} MB';

final class _Digest implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
