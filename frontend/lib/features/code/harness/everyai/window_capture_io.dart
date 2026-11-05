// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'screen_windows.dart';

export 'screen_windows.dart';

/// The windows on screen, frontmost first; empty off macOS or on failure.
/// Windows whose app asked not to be captured (sharing state none, as
/// KeePassXC sets) are left out.
Future<List<ScreenWindow>> listWindows() async {
  if (!Platform.isMacOS) return const [];
  const script = r'''
ObjC.import("CoreGraphics");
var raw = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, $.kCGNullWindowID);
var list = ObjC.deepUnwrap(ObjC.castRefToObject(raw)) || [];
JSON.stringify(list.filter(w => w.kCGWindowLayer == 0 && w.kCGWindowSharingState !== 0).map(w => ({
  id: w.kCGWindowNumber, pid: w.kCGWindowOwnerPID, owner: w.kCGWindowOwnerName || "", title: w.kCGWindowName || "",
  width: Math.round((w.kCGWindowBounds || {}).Width || 0), height: Math.round((w.kCGWindowBounds || {}).Height || 0)
})))''';
  try {
    final res = await Process.run('osascript', ['-l', 'JavaScript', '-e', script]);
    if (res.exitCode != 0) return const [];
    return [
      for (final w in jsonDecode(res.stdout as String) as List<Object?>)
        if (w is Map<String, Object?>)
          (
            id: (w['id'] as num).toInt(),
            pid: (w['pid'] as num).toInt(),
            owner: w['owner'] as String? ?? '',
            title: w['title'] as String? ?? '',
            width: (w['width'] as num?)?.toInt() ?? 0,
            height: (w['height'] as num?)?.toInt() ?? 0,
          ),
    ];
  } on Object {
    return const [];
  }
}

/// The executable of [pid] (its full path on macOS), or ''.
Future<String> executableOf(int pid) async {
  try {
    final res = await Process.run('ps', ['-o', 'comm=', '-p', '$pid']);
    return (res.stdout as String).trim();
  } on Object {
    return '';
  }
}

/// Captures window [id] to [path] as PNG (no shadow, no sound). Null when it
/// worked, else why not.
Future<String?> captureWindow(int id, String path) async {
  File(path).parent.createSync(recursive: true);
  final res = await Process.run('screencapture', ['-x', '-o', '-l$id', path]);
  final file = File(path);
  if (res.exitCode != 0 || !file.existsSync() || file.lengthSync() == 0) {
    return 'screencapture failed${(res.stderr as String).trim().isEmpty ? '' : ': ${(res.stderr as String).trim()}'}. '
        'EveryAI may need Screen Recording permission (System Settings → Privacy & Security → Screen Recording).';
  }
  return null;
}
