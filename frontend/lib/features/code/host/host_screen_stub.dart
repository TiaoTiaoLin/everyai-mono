// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'host.dart' show HostImage;
import 'host_screen.dart';

// Web and mobile run no outside agent, so there is no screen to see.

ScreenAccess screenAccess() => ScreenAccess(
  os: '',
  listWindows: () async => const [],
  executableOf: (_) async => '',
  capture: (_, _, _) async =>
      (text: 'Error: screenshots work on desktop only.', isError: true, images: const <HostImage>[]),
  sessionPids: ({required tag, required workingDir, required ownsDir}) async => const {},
  processTree: (pid) async => {pid},
  spawn: ({required command, required cwd, required sessionTag, required logPath}) =>
      throw UnsupportedError('app_run works on desktop only'),
  browser: (_) => throw UnsupportedError('the browser works on desktop only'),
);

Future<List<String>> detectRunCommandsIn(String dir, String os) async => const [];
