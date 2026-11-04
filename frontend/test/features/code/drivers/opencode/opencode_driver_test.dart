import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_driver.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_host.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_server.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _dir = 'test/fixtures/drivers/opencode';

String _fixture(String name) => File('$_dir/$name').readAsStringSync();

OpenCodeDriver _driver(Future<CliRun> Function(List<String> args) run, {bool installed = true}) =>
    OpenCodeDriver(which: (_) async => installed ? '/bin/echo' : null, run: (exe, args) => run(args));

final class _FakeProcess implements DriverProcess {
  _FakeProcess(List<String> out, {this.lastError = ''}) : lines = Stream.fromIterable(out).asBroadcastStream();

  @override
  final Stream<String> lines;
  @override
  final String lastError;
  var closed = false;
  final _exit = Completer<int>();

  @override
  int get pid => 1;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void send(String line) {}
  @override
  Future<void> close() async => closed = true;
}

void main() {
  group('detect', () {
    test('signed in when a provider has a key or login', () async {
      final s = await _driver((args) async {
        expect(args, ['auth', 'list', '--standalone', '--format', 'json']);
        return (exitCode: 0, stdout: _fixture('auth_list.json'));
      }).detect();
      expect((s.installed, s.path, s.signedIn, s.problem), (true, '/bin/echo', true, null));
    });

    test('not signed in with no provider, unknown when the list is unreadable, absent when not installed', () async {
      final none = await _driver((_) async => (exitCode: 0, stdout: '[]')).detect();
      expect(none.signedIn, isFalse);
      expect(none.problem, contains('opencode auth login'));
      final bad = await _driver((_) async => (exitCode: 0, stdout: 'not json')).detect();
      expect((bad.installed, bad.signedIn, bad.problem), (true, null, null));
      final missing = await _driver((_) async => fail('not run'), installed: false).detect();
      expect(missing.installed, isFalse);
    });
  });

  test('models are the enabled ones as provider/model, with variants as efforts and the default marked', () async {
    final models = await _driver(
      (args) async => (exitCode: 0, stdout: _fixture(args[1] == 'model.list' ? 'models.json' : 'model_default.json')),
    ).models();
    expect(models.map((m) => m.id), [
      'anthropic/claude-sonnet-5-5',
      'minimax-coding-plan/MiniMax-M3.1-Flash',
      'opencode/claude-sonnet-5-5',
      'opencode/crouton-alpha-free',
    ]);
    final crouton = models.last;
    expect((crouton.label, crouton.isDefault), ('Crouton Alpha Free', true));
    expect(crouton.efforts, ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']);
    expect(models[1].efforts, isEmpty);
    expect(models.where((m) => m.isDefault), hasLength(1));
  });

  test('caps are what the driver does today', () {
    expect(OpenCodeDriver().caps, {
      DriverCap.steer,
      DriverCap.resume,
      DriverCap.approvals,
      DriverCap.perCallApprovals,
      DriverCap.usage,
      DriverCap.skills,
      DriverCap.switchModel,
      DriverCap.effort,
    });
    expect(OpenCodeDriver().info.id, 'opencode');
  });

  group('launcher', () {
    test(
      'reads the address it prints, checks it with the password, and keeps the token out of the arguments',
      () async {
        late List<String> sentArgs;
        late Map<String, String> sentEnv;
        final process = _FakeProcess(['some banner', 'server listening on http://127.0.0.1:51234']);
        final requests = <http.Request>[];
        final client = MockClient((r) async {
          requests.add(r);
          return http.Response(
            jsonEncode({
              'version': '2.1.3',
              'pid': 1,
              'urls': <String>[],
              'paths': {'tmp': '/tmp'},
            }),
            200,
          );
        });
        final briefing = openCodeBriefingEnv(
          const DriverBriefing(
            mcpUrl: 'http://127.0.0.1:7000/mcp',
            mcpToken: 'tok-secret',
            skillDir: '/s/briefing/skills',
          ),
        );
        final server = await launchOpenCode(
          executable: '/bin/opencode',
          cwd: '/work',
          sessionTag: 't',
          logPath: '/tmp/x.log',
          env: briefing,
          client: client,
          spawn:
              ({
                required executable,
                required args,
                required cwd,
                required sessionTag,
                required logPath,
                env = const {},
              }) async {
                sentArgs = args;
                sentEnv = env;
                return process;
              },
        );
        expect(server.base, Uri.parse('http://127.0.0.1:51234'));
        final args = sentArgs, env = sentEnv;
        expect(args, ['serve', '--port', '0', '--hostname', '127.0.0.1']);
        final password = env['OPENCODE_PASSWORD']!;
        expect(password.length, greaterThanOrEqualTo(40));
        expect(env['OPENCODE_DISABLE_AUTOUPDATE'], '1');
        // A repository's own OpenCode config and Claude skills don't load: they'd run before any approval.
        expect(env['OPENCODE_DISABLE_PROJECT_CONFIG'], '1');
        expect(env['OPENCODE_DISABLE_CLAUDE_CODE_SKILLS'], '1');
        expect(env[tokenEnvVar], 'tok-secret');
        expect(env['OPENCODE_CONFIG_CONTENT'], contains('"everyai"'));
        expect(env['OPENCODE_CONFIG_CONTENT'], isNot(contains('tok-secret')));
        expect(args.join(' '), isNot(contains('tok-secret')));
        expect(requests.single.url.path, '/api/info');
        expect(requests.single.headers['authorization'], 'Basic ${base64.encode(utf8.encode('opencode:$password'))}');
        // A second server gets a password of its own.
        final again = await launchOpenCode(
          executable: '/bin/opencode',
          cwd: '/work',
          sessionTag: 't',
          logPath: '/tmp/x.log',
          client: client,
          spawn:
              ({
                required executable,
                required args,
                required cwd,
                required sessionTag,
                required logPath,
                env = const {},
              }) async {
                expect(env['OPENCODE_PASSWORD'], isNot(password));
                expect(env['OPENCODE_DISABLE_PROJECT_CONFIG'], '1');
                expect(env.containsKey('OPENCODE_CONFIG_CONTENT'), isFalse);
                return _FakeProcess(['server listening on http://127.0.0.1:51235']);
              },
        );
        expect(again.base.port, 51235);
      },
    );

    test('a server that never says where it listens, or is not OpenCode 2, is closed with a plain error', () async {
      final quiet = _FakeProcess(['starting'], lastError: 'boom');
      await expectLater(
        launchOpenCode(
          executable: '/x',
          cwd: '/w',
          sessionTag: 't',
          logPath: '/tmp/x.log',
          client: MockClient((_) async => http.Response('', 500)),
          spawn: ({
            required executable,
            required args,
            required cwd,
            required sessionTag,
            required logPath,
            env = const {},
          }) async => quiet,
        ),
        throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains('boom'))),
      );
      expect(quiet.closed, isTrue);
      final old = _FakeProcess(['server listening on http://127.0.0.1:1']);
      await expectLater(
        launchOpenCode(
          executable: '/x',
          cwd: '/w',
          sessionTag: 't',
          logPath: '/tmp/x.log',
          client: MockClient((_) async => http.Response('<html>', 200)),
          spawn: ({
            required executable,
            required args,
            required cwd,
            required sessionTag,
            required logPath,
            env = const {},
          }) async => old,
        ),
        throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains('OpenCode 2'))),
      );
      expect(old.closed, isTrue);
    });
  });

  test('no briefing env without a skill folder', () {
    expect(openCodeBriefingEnv(null), isEmpty);
    expect(openCodeBriefingEnv(const DriverBriefing(mcpUrl: 'http://x', mcpToken: 't')), isEmpty);
    expect(listeningUrl('server listening on http://127.0.0.1:4096'), 'http://127.0.0.1:4096');
    expect(listeningUrl('opencode 2.1.3'), isNull);
  });
}
