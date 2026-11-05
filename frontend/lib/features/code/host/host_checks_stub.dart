// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'host.dart';
import 'host_checks.dart';

// Web and mobile run no outside agent, so no checks.

const _none = (text: 'Error: checks run on desktop only.', isError: true);

Future<HostResult> hostCheck(HostCheckContext c, List<String> files, Future<void> cancel) async => _none;

Future<HostResult> hostDiffStatsHere(HostCheckContext c, Future<void> cancel) async => _none;

Future<HostResult> hostBugCheck(HostCheckContext c, Map<String, Object?> args, Future<void> cancel) async => _none;

Future<Map<String, Object?>?> readBugCheckState(String stateDir) async => null;

Future<void> writeBugCheckState(String stateDir, Map<String, Object?> record) async {}
