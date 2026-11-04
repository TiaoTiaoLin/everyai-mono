// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../skills/domain/skill_format.dart' show parseFrontMatter;
import '../../harness/everyai/shell_io.dart' show ShellEnv;

Future<Map<String, Object?>?> readJsonFile(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    final json = jsonDecode(await f.readAsString());
    return json is Map<String, Object?> ? json : null;
  } on Object {
    return null;
  }
}

Future<void> writeJsonFile(String path, Object? json) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(jsonEncode(json), flush: true);
  await tmp.rename(path);
}

Future<List<({String name, String description})>> listSkills(String skillDir) async {
  final dir = Directory(skillDir);
  if (!await dir.exists()) return const [];
  final out = <({String name, String description})>[];
  final folders = await dir.list().where((e) => e is Directory).cast<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final d in folders) {
    final file = File('${d.path}/SKILL.md');
    if (!await file.exists()) continue;
    try {
      final fields = parseFrontMatter(await file.readAsString()).fields;
      final name = fields['name'];
      if (name is! String || name.isEmpty) continue;
      out.add((name: name, description: '${fields['description'] ?? ''}'));
    } on FormatException {
      // The export checked it; a broken one is left out of the list.
    }
  }
  return out;
}

Future<String?> whichCommand(String command) async {
  if (command.startsWith('/')) return File(command).existsSync() ? command : null;
  try {
    final shell = await ShellEnv.load();
    final res = await Process.run('/usr/bin/which', [command], environment: shell.env);
    final path = '${res.stdout}'.trim().split('\n').first.trim();
    return res.exitCode == 0 && path.isNotEmpty ? path : null;
  } on Object {
    return null;
  }
}

Future<bool?> geminiSignedIn({String? home, Map<String, String>? env}) async {
  final vars = env ?? (await ShellEnv.load()).env;
  if (['GEMINI_API_KEY', 'GOOGLE_API_KEY'].any((k) => (vars[k] ?? '').isNotEmpty)) return true;
  final dir = '${home ?? vars['HOME'] ?? Platform.environment['HOME'] ?? ''}/.gemini';
  final settings = await readJsonFile('$dir/settings.json');
  final security = settings?['security'];
  final auth = security is Map<String, Object?> ? security['auth'] : null;
  final type = (auth is Map<String, Object?> ? auth['selectedType'] : null) ?? settings?['selectedAuthType'];
  return switch (type) {
    'oauth-personal' => File('$dir/oauth_creds.json').exists(),
    // A key type without the key in the environment.
    'gemini-api-key' => false,
    // Vertex AI, Cloud Shell, ...: their credentials live elsewhere.
    final String _ => null,
    _ => false,
  };
}

Future<bool?> openCodeSignedIn(String executable) async {
  try {
    final shell = await ShellEnv.load();
    final res = await Process.run(executable, const [
      'auth',
      'list',
      '--standalone',
      '--format',
      'json',
    ], environment: shell.env).timeout(const Duration(seconds: 10));
    if (res.exitCode != 0) return null;
    final list = jsonDecode('${res.stdout}');
    if (list is! List<Object?>) return null;
    return list.any((p) => p is Map<String, Object?> && (p['connections'] as List<Object?>? ?? const []).isNotEmpty);
  } on Object {
    return null;
  }
}
