import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'agent_settings.dart';
import 'settings.dart' show localSettingsPath, projectSettingsPath;

Future<AgentSettings> loadAgentSettings(String projectDir) async {
  final user = await _userSettings();
  return AgentSettings.layered([
    if (user != null) ?await _read(user),
    for (final path in ['$projectDir/$projectSettingsPath', '$projectDir/$localSettingsPath'])
      if (await _read(path) case final raw?) AgentSettings.untrusted(raw),
  ]);
}

Future<String?> userSettingsPath() => _userSettings();

Future<Map<String, Object?>> readLayer(String path) async {
  final f = File(path);
  if (!f.existsSync()) return {};
  final text = await f.readAsString();
  if (text.trim().isEmpty) return {};
  final json = jsonDecode(text);
  if (json is! Map<String, Object?>) throw FormatException('$path is not a JSON object.');
  return json;
}

Future<Map<String, Object?>> writeLayer(
  String path,
  Map<String, Object?> Function(Map<String, Object?> current) edit,
) async {
  final next = edit(await readLayer(path));
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.$pid.tmp');
  await tmp.writeAsString('${const JsonEncoder.withIndent('  ').convert(next)}\n', flush: true);
  await tmp.rename(path);
  return next;
}

/// App Support `settings.json`; null where there is no app (headless tools).
Future<String?> _userSettings() async {
  try {
    return '${(await getApplicationSupportDirectory()).path}/settings.json';
  } on Object {
    return null;
  }
}

Future<Map<String, Object?>?> _read(String path) async {
  final f = File(path);
  if (!f.existsSync()) return null;
  try {
    final json = jsonDecode(await f.readAsString());
    return json is Map<String, Object?> ? json : null;
  } on Object {
    return null;
  }
}

Future<CommitStyle> resolveCommitStyle(String projectDir, CommitStyle style) async {
  if (style != CommitStyle.auto) return style;
  try {
    final res = await Process.run('git', ['-C', projectDir, 'log', '-30', '--format=%s']);
    if (res.exitCode != 0) return CommitStyle.conventional;
    return detectCommitStyle(const LineSplitter().convert(res.stdout as String));
  } on Object {
    return CommitStyle.conventional;
  }
}

Future<void> excludeFromGit(String workingDir, List<String> anchored) async {
  final ProcessResult res;
  try {
    res = await Process.run('git', [
      '-C',
      workingDir,
      'rev-parse',
      '--path-format=absolute',
      '--git-common-dir',
      '--show-prefix',
    ]);
  } on Object {
    return;
  }
  if (res.exitCode != 0) return;
  final out = const LineSplitter().convert(res.stdout as String);
  if (out.isEmpty) return;
  // info/exclude patterns are anchored at the repository's top: a session in
  // a subfolder of the repository gets its folder in front.
  final prefix = out.length > 1 ? out[1].trim() : '';
  final patterns = [for (final p in anchored) p.startsWith('/') ? '/$prefix${p.substring(1)}' : p];
  final exclude = File('${out.first.trim()}/info/exclude');
  final lines = exclude.existsSync() ? await exclude.readAsLines() : <String>[];
  // Earlier versions excluded all of .everyai/, which hid the committed settings.
  final kept = [
    for (final l in lines)
      if (l.trim() != '.everyai/') l,
  ];
  final missing = [
    for (final p in patterns)
      if (!kept.any((l) => l.trim() == p)) p,
  ];
  if (missing.isEmpty && kept.length == lines.length) return;
  await exclude.parent.create(recursive: true);
  await exclude.writeAsString('${[...kept, ...missing].join('\n')}\n');
}
