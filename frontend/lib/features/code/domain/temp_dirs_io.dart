// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

List<String>? _cached;

/// The OS temp folders, each ending in `/`: `/tmp`, `/private/tmp`, `$TMPDIR`
/// and [Directory.systemTemp], with macOS's `/private` aliases. Writes there
/// don't ask (see `PermissionPolicy.tempDirs`).
List<String> systemTempDirs() => _cached ??= _find();

List<String> _find() {
  // The policy compares `/` paths only.
  if (Platform.isWindows) return const [];
  final out = <String>{};
  void add(String? dir) {
    if (dir == null || dir.isEmpty || !dir.startsWith('/') || dir == '/') return;
    final d = dir.endsWith('/') ? dir : '$dir/';
    out.add(d);
    // macOS: /tmp and /var are links into /private.
    if (d.startsWith('/private/')) {
      out.add(d.substring('/private'.length));
    } else if (d.startsWith('/tmp/') || d.startsWith('/var/')) {
      out.add('/private$d');
    }
  }

  add('/tmp');
  add(Platform.environment['TMPDIR']);
  add(Directory.systemTemp.path);
  try {
    add(Directory.systemTemp.resolveSymbolicLinksSync());
  } on FileSystemException {
    // Keep the unresolved path.
  }
  return out.toList();
}
