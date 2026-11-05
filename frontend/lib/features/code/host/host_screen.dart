// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../drivers/driver_process.dart' show DriverProcess;
import '../harness/everyai/screen_windows.dart';
import 'host.dart';
import 'host_screen_stub.dart' if (dart.library.io) 'host_screen_io.dart' as impl;

export '../harness/everyai/screen_windows.dart';

// Seeing what an outside agent builds: screenshots of the session's own app
// windows (another app's window asks the user first), the EveryAI harness's
// headless browser, and app_run, which starts the project's app the way the
// user confirmed once.

const screenshotTool = 'screenshot';
const browserTool = 'browser';
const appRunTool = 'app_run';

/// The screen tools, for a host that offers them (workflow agents too).
const screenHostTools = {screenshotTool, browserTool, appRunTool};

/// [screenshotTool]'s spec (MCP shape).
const screenshotSpec = <String, Object?>{
  'name': screenshotTool,
  'description':
      'Take a screenshot of a desktop app\'s window and look at it. Windows of apps this session started (run from '
      'your shell or by app_run, or built in this folder) are captured at once. To see another app\'s window, name '
      'it with app or window_id: the user is asked once per window and may say no. The picture comes with the '
      'result and its file path is in the text. macOS only for now; for web pages use browser.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'app': {'type': 'string', 'description': 'App or window name to pick'},
      'window_id': {'type': 'integer', 'description': 'A window id app_run returned'},
    },
    'additionalProperties': false,
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};

/// [appRunTool]'s spec (MCP shape).
const appRunSpec = <String, Object?>{
  'name': appRunTool,
  'description':
      'Start the project\'s app the way the user runs it, as a background process of this session, and get its '
      'window ids for screenshot (or its local URL for browser). The first time, the app finds the run command '
      '(flutter run, the package.json dev script, cargo run, …) and the user confirms it once; later calls reuse '
      'that command, and the copy already running. It waits up to 2 minutes for a window or a URL: call it again '
      'when it says the app is still starting. The app stops with the session.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'command': {'type': 'string', 'description': 'A run command to suggest; the user confirms it'},
      'restart': {'type': 'boolean', 'description': 'Stop the running copy and start again (after a native change)'},
    },
    'additionalProperties': false,
  },
  'annotations': {'readOnlyHint': false, 'destructiveHint': false},
};

/// Where app_run keeps the confirmed command in a project's
/// `settings.local.json`.
const runCommandKey = 'run';

/// The run commands a project's files suggest, best first. [exists] and
/// [read] see paths relative to the session folder; [dirs] are the folders
/// to look in ('' for the session folder, then subfolders, whose commands
/// start with `cd <dir> &&`). [os] is the desktop `flutter run -d` targets.
List<String> detectRunCommands({
  required bool Function(String path) exists,
  required String? Function(String path) read,
  required String os,
  List<String> dirs = const [''],
}) {
  final out = <String>[];
  for (final dir in dirs) {
    String at(String f) => dir.isEmpty ? f : '$dir/$f';
    void add(String command) {
      final c = dir.isEmpty ? command : 'cd $dir && $command';
      if (!out.contains(c)) out.add(c);
    }

    if (read(at('pubspec.yaml')) case final pubspec?) {
      final flutter = RegExp(r'^\s*sdk:\s*flutter\s*$|^flutter:', multiLine: true).hasMatch(pubspec);
      add(flutter ? 'flutter run -d $os' : 'dart run');
    }
    if (read(at('package.json')) case final pkg?) {
      final scripts = switch (_json(pkg)) {
        {'scripts': final Map<String, Object?> s} => s,
        _ => const <String, Object?>{},
      };
      if (['dev', 'start', 'serve'].where(scripts.containsKey).firstOrNull case final script?) {
        // The lockfile says which package manager the project uses.
        final runner = exists(at('pnpm-lock.yaml'))
            ? 'pnpm run'
            : exists(at('yarn.lock'))
            ? 'yarn'
            : exists(at('bun.lock')) || exists(at('bun.lockb'))
            ? 'bun run'
            : 'npm run';
        add('$runner $script');
      }
    }
    if (exists(at('Cargo.toml'))) add('cargo run');
    if (exists(at('go.mod'))) add('go run .');
    if (exists(at('Package.swift'))) add('swift run');
    if (read(at('Makefile')) case final make? when RegExp(r'^run\s*:', multiLine: true).hasMatch(make)) {
      add('make run');
    }
  }
  return out;
}

Object? _json(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// [detectRunCommands] on [dir] and its subfolders one level down.
Future<List<String>> detectRunCommandsIn(String dir, String os) => impl.detectRunCommandsIn(dir, os);

/// A screen tool's result: text, and pictures for the agent.
typedef ScreenResult = ({String text, bool isError, List<HostImage> images});

/// A headless browser of the session's own.
abstract interface class ScreenBrowser {
  /// One `browser` tool call; screenshots are saved under [root].
  Future<ScreenResult> run(Map<String, Object?> args, String root);
  Future<void> close();
}

/// What the screen tools reach on this computer; tests fake it.
final class ScreenAccess {
  const ScreenAccess({
    required this.os,
    required this.listWindows,
    required this.executableOf,
    required this.capture,
    required this.sessionPids,
    required this.processTree,
    required this.spawn,
    required this.browser,
    this.poll = _aSecond,
  });

  /// `Platform.operatingSystem`: macos, linux, windows ('' on the web).
  final String os;

  /// The windows on screen, frontmost first.
  final Future<List<ScreenWindow>> Function() listWindows;

  /// The executable of a process ('' when unknown).
  final Future<String> Function(int pid) executableOf;

  /// Captures a window into [root]'s scratch folder; [others] more matched.
  final Future<ScreenResult> Function(ScreenWindow w, String root, int others) capture;

  /// The processes of session [tag]: its shells and what they run.
  final Future<Set<int>> Function({required String tag, required String workingDir, required bool ownsDir}) sessionPids;

  /// [pid] and its children.
  final Future<Set<int>> Function(int pid) processTree;

  /// Starts [command] in [cwd] as a process of session [sessionTag], its
  /// stderr in its stdout; closing it ends its process tree.
  final Future<DriverProcess> Function({
    required String command,
    required String cwd,
    required String sessionTag,
    required String logPath,
  })
  spawn;

  /// A headless browser keeping its profile in [profileDir].
  final ScreenBrowser Function(String profileDir) browser;

  /// Waits between two looks for app_run's window.
  final Future<void> Function() poll;
}

Future<void> _aSecond() => Future<void>.delayed(const Duration(seconds: 1));

final screenAccessProvider = Provider<ScreenAccess>((ref) => impl.screenAccess());

/// The image in a data URL ("data:image/png;base64,…"), or null.
HostImage? hostImageOf(String dataUrl) {
  final m = RegExp(r'^data:([^;,]+);base64,(.*)$', dotAll: true).firstMatch(dataUrl);
  return m == null ? null : (mime: m.group(1)!, data: m.group(2)!);
}
