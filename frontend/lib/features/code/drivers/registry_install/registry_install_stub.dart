// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:http/http.dart' as http;

import 'acp_registry.dart';

String? currentPlatformKey() => null;

Future<void> chmodExecutable(String path) async {}

Future<String> installBinary({
  required String root,
  required String id,
  required String version,
  required BinaryTarget target,
  required http.Client client,
  required Future<void> Function(String path) makeExecutable,
  required int maxDownload,
  required int maxUnpacked,
}) => throw InstallError("Agents can't be downloaded here.");

Future<void> removeAgentFiles(String root, String id) async {}
