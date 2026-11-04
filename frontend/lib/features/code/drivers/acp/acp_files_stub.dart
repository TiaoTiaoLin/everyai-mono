// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

Future<Map<String, Object?>?> readJsonFile(String path) async => null;

Future<void> writeJsonFile(String path, Object? json) async {}

Future<List<({String name, String description})>> listSkills(String skillDir) async => const [];

Future<String?> whichCommand(String command) async => null;

Future<bool?> geminiSignedIn({String? home, Map<String, String>? env}) async => null;

Future<Map<String, String>> loginEnv() async => const {};

Future<bool?> openCodeSignedIn(String executable) async => null;

Future<bool?> kiroSignedIn(String executable) async => null;

Future<String?> geminiWorkspaceProblem(String cwd, {required String folder, required String label}) async => null;

Future<String?> kiroWorkspaceProblem(String cwd) async => null;
