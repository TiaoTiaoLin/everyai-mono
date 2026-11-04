// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

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
  Duration idle = downloadIdleTimeout,
}) async {
  final agentDir = '$root/$id';
  final dest = Directory('$agentDir/$version');
  final part = Directory('$agentDir/$version.part');
  if (part.existsSync()) part.deleteSync(recursive: true);
  part.createSync(recursive: true);
  try {
    final suffix = _suffix(target.archive);
    final download = File('${part.path}/download$suffix');
    final res = await client
        .send(http.Request('GET', Uri.parse(target.archive)))
        .timeout(idle, onTimeout: () => throw const InstallError(_stalled));
    if (res.statusCode != 200) throw InstallError('The download failed (HTTP ${res.statusCode}).');
    final sink = download.openWrite();
    final digest = _Digest();
    final hasher = sha256.startChunkedConversion(digest);
    var size = 0;
    try {
      await for (final chunk in res.stream.timeout(
        idle,
        onTimeout: (sink) => sink.addError(const InstallError(_stalled)),
      )) {
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
      // Unpacking is synchronous work that can take seconds, so it runs off
      // the UI isolate.
      // A tear-off of a plain object, so the isolate is sent nothing else.
      final (:outside, :error) = await Isolate.run(_Unpack(download.path, files.path, maxUnpacked).call);
      if (error != null) throw InstallError("Couldn't unpack the download: $error");
      if (outside != null) {
        throw InstallError('The download has files outside its folder ($outside), so nothing was installed.');
      }
      await download.delete();
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
    if (await dest.exists()) await dest.delete(recursive: true);
    await files.rename(dest.path);
    await part.delete(recursive: true);
    // Older versions go once the new one is in place.
    await for (final other in Directory(agentDir).list()) {
      if (other.path.split('/').last != version) await other.delete(recursive: true);
    }
    return '${dest.path}/${target.cmd}';
  } on Object {
    if (part.existsSync()) part.deleteSync(recursive: true);
    rethrow;
  }
}

/// Unpacks [archive] into [dir] (in a background isolate): the first entry
/// that would leave [dir], or what package:archive refused.
final class _Unpack {
  const _Unpack(this.archive, this.dir, this.maxSize);

  final String archive;
  final String dir;
  final int maxSize;

  Future<({String? outside, String? error})> call() async {
    String? outside;
    try {
      await extractFileToDisk(
        archive,
        dir,
        maxSize: maxSize,
        callback: (e) {
          if (leavesFolder(e.name, e.symbolicLink)) outside ??= e.name;
        },
      );
    } on ArchiveException catch (e) {
      return (outside: null, error: e.message);
    }
    return (outside: outside, error: null);
  }
}

const _stalled = 'The download stopped. Try again.';

Future<void> makeDir(String path) => Directory(path).create(recursive: true);

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
