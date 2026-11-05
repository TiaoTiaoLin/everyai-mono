// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

// Which GitHub release the app should move to: semantic-version order (pre-releases before their release), the
// channel (only GitHub's latest release, or pre-releases too) and the files a release carries.

/// A version like `0.1.0-alpha.2` (a leading `v` and any `+build` are ignored). Ordered as in semver: numbers first,
/// then a version with a pre-release part comes before the same version without one; pre-release parts compare
/// numerically when both are numbers, else as text.
final class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.core, this.pre);

  final List<int> core;
  final List<String> pre;

  static ReleaseVersion? tryParse(String text) {
    var s = text.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    final dash = s.indexOf('-');
    final coreText = dash >= 0 ? s.substring(0, dash) : s;
    final core = <int>[];
    for (final part in coreText.split('.')) {
      final n = int.tryParse(part);
      if (n == null || n < 0) return null;
      core.add(n);
    }
    if (core.isEmpty || core.length > 4) return null;
    while (core.length < 3) {
      core.add(0);
    }
    final pre = dash >= 0 ? s.substring(dash + 1).split('.').where((p) => p.isNotEmpty).toList() : <String>[];
    return ReleaseVersion(core, pre);
  }

  bool get isPrerelease => pre.isNotEmpty;

  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < core.length || i < other.core.length; i++) {
      final a = i < core.length ? core[i] : 0;
      final b = i < other.core.length ? other.core[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    if (pre.isEmpty || other.pre.isEmpty) return (pre.isEmpty ? 1 : 0) - (other.pre.isEmpty ? 1 : 0);
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = int.tryParse(pre[i]);
      final b = int.tryParse(other.pre[i]);
      final c = a != null && b != null
          ? a.compareTo(b)
          : a != null
          ? -1
          : b != null
          ? 1
          : pre[i].compareTo(other.pre[i]);
      if (c != 0) return c;
    }
    return pre.length.compareTo(other.pre.length);
  }

  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(Object.hashAll(core), Object.hashAll(pre));

  @override
  String toString() => '${core.join('.')}${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}

/// A file attached to a release.
final class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, required this.size});
  final String name;

  /// The direct download (`browser_download_url`).
  final String url;
  final int size;
}

/// A published GitHub release (drafts never show to the app).
final class Release {
  const Release({
    required this.tag,
    required this.version,
    required this.prerelease,
    required this.pageUrl,
    required this.notes,
    required this.assets,
  });

  final String tag;
  final ReleaseVersion version;
  final bool prerelease;

  /// The release page ("What's new").
  final String pageUrl;
  final String notes;
  final List<ReleaseAsset> assets;

  /// From the GitHub REST API's release object; null when it isn't one we can use (a draft, an unparsable tag).
  static Release? fromJson(Map<String, Object?> json) {
    if (json['draft'] == true) return null;
    final tag = json['tag_name'];
    if (tag is! String) return null;
    final version = ReleaseVersion.tryParse(tag);
    if (version == null) return null;
    return Release(
      tag: tag,
      version: version,
      prerelease: json['prerelease'] == true,
      pageUrl: json['html_url'] as String? ?? '',
      notes: json['body'] as String? ?? '',
      assets: [
        for (final a in (json['assets'] as List<Object?>? ?? const []))
          if (a is Map<String, Object?> && a['name'] is String && a['browser_download_url'] is String)
            ReleaseAsset(
              name: a['name']! as String,
              url: a['browser_download_url']! as String,
              size: (a['size'] as num?)?.toInt() ?? 0,
            ),
      ],
    );
  }

  ReleaseAsset? asset(bool Function(String name) test) {
    for (final a in assets) {
      if (test(a.name)) return a;
    }
    return null;
  }

  ReleaseAsset? get appcast => asset((n) => n == 'appcast.xml');
  ReleaseAsset? get appImage => asset((n) => n.endsWith('.AppImage'));
  ReleaseAsset? get deb => asset((n) => n.endsWith('.deb'));
  ReleaseAsset? get checksums => asset((n) => n == 'SHA256SUMS');
  ReleaseAsset? get checksumsSignature => asset((n) => n == 'SHA256SUMS.sig');
}

/// The newest release above [current] that the channel allows, or null when the app is up to date. With
/// [prereleases] off only stable releases count (GitHub's "latest").
Release? pickUpdate(Iterable<Release> releases, ReleaseVersion current, {required bool prereleases}) {
  Release? best;
  for (final r in releases) {
    if (r.prerelease && !prereleases) continue;
    if (!(r.version > current)) continue;
    if (best == null || r.version > best.version) best = r;
  }
  return best;
}

/// The SHA-256 listed for [file] in a `sha256sum` output, or null.
String? checksumFor(String sums, String file) {
  for (final line in sums.split('\n')) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null && m.group(2)!.trim() == file) return m.group(1)!.toLowerCase();
  }
  return null;
}

/// An update that couldn't be fetched or verified; [message] is for the user.
final class UpdateError implements Exception {
  const UpdateError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Whether [signature] (base64 Ed25519, from `packaging/updates.py sign`) signs exactly [text] with [publicKey]
/// (base64, 32 bytes). Malformed input is false.
Future<bool> verifySigned(String text, String signature, {required String publicKey}) async {
  try {
    return await Ed25519().verify(
      utf8.encode(text),
      signature: Signature(
        base64.decode(signature.trim()),
        publicKey: SimplePublicKey(base64.decode(publicKey), type: KeyPairType.ed25519),
      ),
    );
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}
