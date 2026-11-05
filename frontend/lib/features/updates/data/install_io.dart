// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/services.dart';

import 'dart:ui' show AppExitType;

import 'package:http/http.dart' as http;

import '../domain/releases.dart';
import '../update_key.dart';
import 'install.dart';

/// On Linux: an AppImage (the runtime sets `APPIMAGE` to its file) or the .deb (installed under /opt/everyai).
InstallKind linuxInstallKind() {
  if (!Platform.isLinux) return InstallKind.none;
  final image = Platform.environment['APPIMAGE'];
  if (image != null && image.isNotEmpty && File(image).existsSync()) return InstallKind.appImage;
  if (Platform.resolvedExecutable.startsWith('/opt/everyai/')) return InstallKind.deb;
  return InstallKind.none;
}

bool get isMacOS => Platform.isMacOS;

/// `EVERYAI_UPDATES_API`: another releases endpoint (same JSON as GitHub's), for testing the updater end to end.
String? get releasesApiOverride => Platform.environment['EVERYAI_UPDATES_API'];

/// Downloads [release]'s AppImage next to the running one, checks it against SHA256SUMS and that file's Ed25519
/// signature (our release key), and moves it over the running file. The running copy keeps working (Linux keeps
/// the old file open); the next start is the new version. Throws, leaving the old file alone, on any mismatch.
Future<void> stageAppImage(Release release, {required http.Client client, void Function(double)? onProgress}) async {
  final target = Platform.environment['APPIMAGE'];
  final image = release.appImage;
  final sums = release.checksums;
  final sig = release.checksumsSignature;
  if (target == null || image == null || sums == null || sig == null) {
    throw const UpdateError('This release has no signed AppImage.');
  }
  final sumsText = await _text(client, sums.url);
  final ok = await verifySigned(sumsText, await _text(client, sig.url), publicKey: updatePublicKey);
  if (!ok) throw const UpdateError("The release's checksums aren't signed by EveryAI.");
  final expected = checksumFor(sumsText, image.name);
  if (expected == null) throw const UpdateError('The AppImage is not in the signed checksums.');

  final part = File('$target.update');
  final dir = part.parent;
  try {
    if (await part.exists()) await part.delete();
    final res = await client.send(http.Request('GET', Uri.parse(image.url)));
    if (res.statusCode != 200) throw UpdateError('Download failed (HTTP ${res.statusCode}).');
    final total = res.contentLength ?? image.size;
    var got = 0;
    final sink = part.openWrite();
    await res.stream
        .map((chunk) {
          got += chunk.length;
          if (total > 0) onProgress?.call(got / total);
          return chunk;
        })
        .pipe(sink);
    final digest = await hash.sha256.bind(part.openRead()).first;
    if (digest.toString() != expected) throw const UpdateError("The download doesn't match the signed checksum.");
    final chmod = await Process.run('chmod', ['755', part.path]);
    if (chmod.exitCode != 0) throw UpdateError('Could not make the update executable: ${chmod.stderr}');
    await part.rename(target);
  } on FileSystemException catch (e) {
    throw UpdateError("Can't write next to the AppImage in ${dir.path} (${e.osError?.message ?? e.message}).");
  } finally {
    if (await part.exists()) await part.delete().catchError((_) => part);
  }
}

/// Starts the (replaced) AppImage once this process is gone, then quits through the normal exit path (sessions and
/// CLIs shut down as on any quit).
Future<void> restartAppImage() async {
  final target = Platform.environment['APPIMAGE'];
  if (target == null) return;
  await Process.start('/bin/sh', [
    '-c',
    'while kill -0 "\$1" 2>/dev/null; do sleep 0.3; done; exec "\$2"',
    'sh',
    '$pid',
    target,
  ], mode: ProcessStartMode.detached);
  await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
}

Future<String> _text(http.Client client, String url) async {
  final res = await client.get(Uri.parse(url));
  if (res.statusCode != 200) throw UpdateError('Download failed (HTTP ${res.statusCode}).');
  return res.body;
}
