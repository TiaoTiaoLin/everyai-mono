// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../skills/domain/skill_format.dart' show parseFrontMatter;
import '../../harness/everyai/shell_io.dart' show ShellEnv;
import 'acp_agents.dart' show cursorSignedInFrom, kiroSignedInFrom;

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

var _writes = 0;

Future<void> writeJsonFile(String path, Object? json) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  // A temporary name of its own, so two writers of one file don't collide.
  final tmp = File('$path.$pid.${_writes++}.tmp');
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

Future<Map<String, String>> loginEnv() async => (await ShellEnv.load()).env;

Future<bool?> geminiSignedIn({String? home, Map<String, String>? env}) async {
  final vars = env ?? (await ShellEnv.load()).env;
  final root = home ?? vars['HOME'] ?? Platform.environment['HOME'] ?? '';
  // Gemini CLI also loads `~/.gemini/.env` and `~/.env` (its auth docs
  // suggest them for the key and the Cloud project); only names are read.
  final named = {
    for (final k in vars.keys)
      if ((vars[k] ?? '').isNotEmpty) k,
    ...await _dotEnvNames('$root/.gemini/.env'),
    ...await _dotEnvNames('$root/.env'),
  };
  if (named.contains('GEMINI_API_KEY') || named.contains('GOOGLE_API_KEY')) return true;
  final dir = '$root/.gemini';
  final settings = await readJsonFile('$dir/settings.json');
  final security = settings?['security'];
  final auth = security is Map<String, Object?> ? security['auth'] : null;
  final type = (auth is Map<String, Object?> ? auth['selectedType'] : null) ?? settings?['selectedAuthType'];
  return switch (type) {
    // A personal Google sign-in no longer works; with a Cloud project it may
    // be a Code Assist licence, which the files can't tell apart.
    'oauth-personal' =>
      await File('$dir/oauth_creds.json').exists() &&
              (named.contains('GOOGLE_CLOUD_PROJECT') || named.contains('GOOGLE_CLOUD_PROJECT_ID'))
          ? null
          : false,
    // A key type without the key in the environment.
    'gemini-api-key' => false,
    // Vertex AI, Cloud Shell, ...: their credentials live elsewhere.
    final String _ => null,
    _ => false,
  };
}

/// The names of the variables a `.env` file at [path] sets to something
/// (`NAME=value`, `export NAME=value`); never the values.
Future<Set<String>> _dotEnvNames(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return const {};
    // A value that is empty (`""`, `''`) or only a comment doesn't count.
    final assign = RegExp(r'''^\s*(?:export\s+)?([A-Za-z_]\w*)\s*=\s*(?!""|''|#)\S''');
    return {
      for (final line in await f.readAsLines())
        if (assign.firstMatch(line) case final m?) m.group(1)!,
    };
  } on Object {
    return const {};
  }
}

Future<bool?> openCodeSignedIn(String executable) async {
  // `--standalone` starts a private server: one that hangs is ended, not left behind.
  final out = await _status(executable, const ['auth', 'list', '--standalone', '--format', 'json']);
  if (out == null || out.code != 0) return null;
  try {
    final list = jsonDecode(out.stdout);
    if (list is! List<Object?>) return null;
    return list.any((p) => p is Map<String, Object?> && (p['connections'] as List<Object?>? ?? const []).isNotEmpty);
  } on FormatException {
    return null;
  }
}

Future<bool?> kiroSignedIn(String executable) async {
  final out = await _status(executable, const ['whoami', '--format', 'json']);
  return out == null ? null : kiroSignedInFrom(out.code, out.stdout);
}

Future<bool?> cursorSignedIn() async {
  if (!Platform.isMacOS) return null;
  // Without -w or -g, `security` prints the entry's attributes, never its secret.
  final out = await _status('/usr/bin/security', const [
    'find-generic-password',
    '-s',
    'cursor-access-token',
    '-a',
    'cursor-user',
  ]);
  return out == null ? null : cursorSignedInFrom(out.code);
}

/// [executable] [args]'s exit code and output, or null when it can't run or
/// takes over 10 s (then it is killed, not left behind).
Future<({int code, String stdout})?> _status(String executable, List<String> args) async {
  Process? proc;
  try {
    final shell = await ShellEnv.load();
    final p = proc = await Process.start(executable, args, environment: shell.env);
    unawaited(p.stderr.drain<void>());
    final out = p.stdout.transform(utf8.decoder).join();
    final code = await p.exitCode.timeout(const Duration(seconds: 10));
    return (code: code, stdout: await out);
  } on TimeoutException {
    proc?.kill(ProcessSignal.sigkill);
    return null;
  } on Object {
    return null;
  }
}

Future<String?> geminiWorkspaceProblem(String cwd, {required String folder, required String label}) async {
  final found = <String>[];
  final settings = await readJsonFile('$cwd/$folder/settings.json');
  for (final MapEntry(:key, :value) in (settings ?? const <String, Object?>{}).entries) {
    final harmless =
        _geminiHarmless.contains(key) ||
        (key == 'context' && value is Map<String, Object?> && value['includeDirectories'] == null);
    if (!harmless) found.add('settings.json "$key"');
  }
  for (final d in const ['policies', 'extensions']) {
    if (await Directory('$cwd/$folder/$d').exists()) found.add('$d/');
  }
  if (found.isEmpty) return null;
  return "This project's $folder folder can let $label act without asking the app (${found.join(', ')}). "
      'Remove those, or add MCP servers in Settings → Code → MCP servers instead, then try again.';
}

/// Why Kiro must not start in [cwd]: the project's own agent configs (which
/// can pre-allow tools and run hooks) or MCP servers would act without
/// asking the app. Null when there are none.
Future<String?> kiroWorkspaceProblem(String cwd) async {
  final found = [
    if (await Directory('$cwd/.kiro/agents').exists()) 'agents/',
    if (await File('$cwd/.kiro/settings/mcp.json').exists()) 'settings/mcp.json',
  ];
  if (found.isEmpty) return null;
  return "This project's .kiro folder can let Kiro CLI act without asking the app (${found.join(', ')}). "
      'Remove those, or add MCP servers in Settings → Code → MCP servers instead, then try again.';
}

/// `.gemini/settings.json` keys that can't widen what Gemini does unasked.
const _geminiHarmless = {r'$schema', 'ui', 'general', 'model', 'privacy', 'telemetry', 'output', 'accessibility'};
