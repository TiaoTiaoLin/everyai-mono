// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/harness.dart';
import 'driver.dart';
import 'driver_process.dart';

Future<DriverProcess> spawnDriver({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
}) async => throw const HarnessError('Outside agents run on the desktop app.');

Future<DriverProcess> spawnDriverTty({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
}) async => throw const HarnessError('Outside agents run on the desktop app.');

Future<DriverStatus> detectCli(
  String command, {
  List<String> versionArgs = const ['--version'],
  Future<String?> Function(String command)? which,
}) async => const DriverStatus(problem: 'Needs the desktop app.');

Future<void> closeAllDriverProcesses() async {}
