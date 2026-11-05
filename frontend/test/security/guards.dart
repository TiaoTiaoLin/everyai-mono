import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:every_ai/features/code/domain/notice.dart';
import 'package:every_ai/features/code/domain/permissions.dart' show dangerReason;
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/package_check.dart';
import 'package:every_ai/features/code/harness/everyai/package_registry_io.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart' show browserTarget;
import 'package:every_ai/features/code/harness/everyai/scrub.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/core/security/untrusted.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Adapters for the red-team fixtures: guard id -> what the guarded code made of the case. They call the real tool
// code with fakes (MockClient for the gateway, a fake package registry, temp folders), never the network. See
// README.md.

/// What a guard made of one case. [fences] are the tag names of the block the content must stay inside.
typedef Outcome = ({bool error, bool warned, String text, List<String> fences});

const untrustedFences = ['untrusted-content', 'untrusted_tool_result'];

/// The guard ids [GuardBench.run] knows.
const knownGuards = {
  'web_fetch', 'web_search', 'read', 'grep', 'bash', 'bash_output', 'install', 'approval', 'domain', 'untrusted', //
  'notice',
};

Outcome _out(String text, {bool error = false, bool warned = false, List<String> fences = untrustedFences}) =>
    (error: error, warned: warned, text: text, fences: fences);

/// Secret placeholders (`{{NAME}}`, `{{NAME|pct}}`, `{{NAME|b64}}`) filled with values in known key shapes, made at
/// run time so no secret-shaped string sits in git. The same values go to the [Scrubber] as environment variables.
final class Secrets {
  Secrets([int seed = 20261105]) : _random = Random(seed);

  final Random _random;
  final values = <String, String>{};

  static const _alnum = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  String _run(int n, [String from = _alnum]) => [for (var i = 0; i < n; i++) from[_random.nextInt(from.length)]].join();

  String _make(String name) => switch (name) {
    'GITHUB_TOKEN' => 'ghp_${_run(36)}',
    'OPENAI_API_KEY' => 'sk-${_run(40)}',
    'AWS_ACCESS_KEY_ID' => 'AKIA${_run(16, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567')}',
    'SLACK_TOKEN' => 'xoxb-${_run(12, '0123456789')}-${_run(24)}',
    'PRIVATE_KEY' => '-----BEGIN OPENSSH ${'PRIVATE'} KEY-----\n${_run(64)}\n-----END OPENSSH ${'PRIVATE'} KEY-----',
    // A secret-named variable's value with no known shape: only the environment says it is one.
    _ => 'Zq${_run(18)}9',
  };

  /// [text] with its placeholders filled.
  String fill(String text) => text.replaceAllMapped(RegExp(r'\{\{([A-Z_]+)(?:\|(pct|b64))?\}\}'), (m) {
    final v = values[m[1]!] ??= _make(m[1]!);
    return switch (m[2]) {
      'pct' => [for (final c in utf8.encode(v)) '%${c.toRadixString(16).padLeft(2, '0').toUpperCase()}'].join(),
      'b64' => base64Url.encode(utf8.encode(v)),
      _ => v,
    };
  });

  /// [input] with every string in it filled.
  Object? fillAll(Object? input) => switch (input) {
    final String s => fill(s),
    final Map<String, Object?> m => {for (final e in m.entries) e.key: fillAll(e.value)},
    final List<Object?> l => [for (final v in l) fillAll(v)],
    _ => input,
  };

  /// The filled values as environment variables (the names are secret-named, so the [Scrubber] keeps them).
  Map<String, String> get env => {for (final e in values.entries) e.key: e.value};
}

/// One case's sandbox: a project folder and a folder outside it, under a temp dir.
final class GuardBench {
  GuardBench(this.secrets)
    : tmp = Directory(Directory.systemTemp.createTempSync('everyai-redteam').resolveSymbolicLinksSync()) {
    Directory(root).createSync();
    Directory(outside).createSync();
  }

  final Secrets secrets;
  final Directory tmp;
  String get root => '${tmp.path}/project';
  String get outside => '${tmp.path}/elsewhere';
  SessionShell? _shell;

  Future<void> dispose() async {
    await _shell?.killAll();
    tmp.deleteSync(recursive: true);
  }

  ToolRunner _runner(Map<String, Object?> input, {String payload = '', PackageGuard? packages}) {
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/fetch')) {
        final url = (jsonDecode(req.body) as Map)['url'] as String;
        // As the backend answers: the page in its own fence.
        final text = input['backend_fence'] == false
            ? payload
            : '<untrusted_tool_result source="$url">\n$payload\n</untrusted_tool_result>';
        return http.Response(jsonEncode({'url': url, 'text': text}), 200, headers: _json);
      }
      // A web search: one result whose snippet is the payload.
      final citation = {
        'url': input['result_url'] ?? 'https://docs.example.com/a',
        'title': input['title'] ?? 'A result',
        'content': payload,
      };
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': '',
                'annotations': [
                  {'url_citation': citation},
                ],
              },
            },
          ],
        }),
        200,
        headers: _json,
      );
    });
    final sites = (input['research_sites'] as List?)?.cast<String>();
    return ToolRunner(
      root: root,
      shell: _shell ??= SessionShell(root: root, sessionTag: 'redteam', scratchDir: '${tmp.path}/.sh'),
      gateway: GatewayClient(baseUrl: 'http://gateway.invalid/v1', apiKey: 'sk-eai-redteam', client: client),
      sessionTag: '',
      researchSites: sites,
      scrubber: Scrubber(env: secrets.env),
      pushTargets: const {'origin'},
      packages: packages,
    );
  }

  static const _json = {'content-type': 'application/json; charset=utf-8'};

  /// Writes [payload] to [path] (`~/` never: home paths are only checked, never read), relative to the project or,
  /// with [outsideProject], to the folder outside it. Returns the absolute path.
  String _place(String path, String payload, {bool outsideProject = false}) {
    final abs = path.startsWith('/') ? path : '${outsideProject ? outside : root}/$path';
    File(abs)
      ..createSync(recursive: true)
      ..writeAsStringSync(payload);
    return abs;
  }

  /// A tool's result as the model gets it: the session hides secrets in every tool's text (`_result`).
  Outcome _seen(ToolRunner runner, ToolOutput out, {bool warned = false}) =>
      _out(runner.scrubber.redact(out.text), error: out.isError, warned: warned);

  Future<Outcome> run(String guard, Map<String, Object?> input, String payload) async {
    switch (guard) {
      // input: url; research_sites (a research job); backend_fence: false (a page without the backend's fence).
      case 'web_fetch':
        final runner = _runner(input, payload: payload);
        final out = await runner.run('web_fetch', {'url': input['url']});
        return _seen(runner, out, warned: out.text.startsWith('Note:'));
      // input: query; title and result_url of the one result (the payload is its snippet).
      case 'web_search':
        final runner = _runner(input, payload: payload);
        return _seen(runner, await runner.run('web_search', {'query': input['query']}));
      // input: file (the payload is written there, in the project or with outside: true next to it) or path (`~/…`
      // is checked only); research_sites; for grep, pattern and output_mode.
      case 'read' || 'grep':
        final runner = _runner(input);
        var path = input['path'] as String? ?? '';
        if (input['file'] case final String file) {
          path = _place(file, payload, outsideProject: input['outside'] == true);
        }
        final args = guard == 'read'
            ? {'file_path': path}
            : {'pattern': input['pattern'], 'path': path, 'output_mode': input['output_mode'] ?? 'content'};
        // A path in the real home folder is only checked: a guard that isn't there must not read the user's files.
        if (path.startsWith('~/')) {
          final refusal = runner.refusalBeforeApproval(guard, args);
          return _out(refusal ?? '(checked only: home paths are never read here)', error: refusal != null);
        }
        return _seen(runner, await runner.run(guard, args));
      // input: command.
      case 'bash':
        // Checked, never run: a guard that isn't there must not send anything anywhere.
        final refusal = _runner(input).refusalBeforeApproval('bash', {'command': input['command']});
        return _out(refusal ?? '(checked only: not run)', error: refusal != null);
      // input: command, run in the project, where payload.txt holds the payload.
      case 'bash_output':
        // Runs a harmless command whose output is the payload (a shell function stands in for gh, curl, env, …).
        _place('payload.txt', payload);
        final runner = _runner(input);
        return _seen(runner, await runner.run('bash', {'command': input['command']}));
      // input: command; registry: {'npm:name': 'missing' | 'new' | 'old'} (popular names aren't looked up).
      case 'install':
        final registry = {
          for (final e in ((input['registry'] as Map?) ?? const {}).entries)
            e.key as String: switch (e.value) {
              'missing' => PackageInfo.missing,
              'new' => PackageInfo(created: DateTime.now().subtract(const Duration(days: 2)), downloads: 3),
              _ => PackageInfo(created: DateTime.utc(2018), downloads: 500000),
            },
        };
        final packages = PackageGuard(_Registry(registry), env: const {});
        final runner = _runner(input, packages: packages);
        final command = input['command'] as String;
        final refusal = await runner.packageRefusal('bash', {'command': command});
        if (refusal != null) return _out(refusal, error: true);
        final notes = (await packages.check(command, cwd: root, root: root)).notes;
        return _out(notes.isEmpty ? '(allowed: not run)' : notes.join('\n'), warned: notes.isNotEmpty);
      // input: command.
      case 'approval':
        // Not a refusal: the call is put to the user (outside Full auto and Bypass).
        final why = dangerReason(input['command'] as String);
        return _out(why ?? '(no approval needed)', warned: why != null);
      // input: url.
      case 'domain':
        // The browser tool's check; the backend runs its Zig twin on every fetch (official_sites_cases.txt).
        final v = browserTarget(input['url'] as String);
        return _out(v.refusal ?? v.notice ?? '(allowed)', error: v.refusal != null, warned: v.notice != null);
      // input: source.
      case 'untrusted':
        // No tool path of its own: the tools call it (covered by the web_fetch, read and bash_output cases).
        return _out(untrusted(payload, source: input['source'] as String? ?? 'test'));
      // input: as: 'task-notification' (the payload is a background fork's report) or nothing (a plain report).
      case 'notice':
        final body = input['as'] == 'task-notification'
            ? taskNotification('f1', 'Fork', SubagentReport(SubagentStatus.completed, payload))
            : payload;
        return _out(
          wrapNotice(kind: 'fork-report', id: 'f1', nonce: 'feedface', body: body),
          fences: [noticeTag, if (input['as'] == 'task-notification') 'task-notification'],
        );
    }
    throw ArgumentError('no adapter for guard "$guard"; add one in guards.dart');
  }
}

final class _Registry implements PackageLookup {
  _Registry(this.answers);
  final Map<String, PackageInfo> answers;

  @override
  Future<PackageInfo?> info(PackageRef p) async => answers[p.key];
}
