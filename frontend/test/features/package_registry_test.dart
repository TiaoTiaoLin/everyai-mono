import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/package_check.dart';
import 'package:every_ai/features/code/harness/everyai/package_registry_io.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Registry answers by URL path (small fixtures written by hand, shaped like each registry's JSON).
const _fixtures = <String, Object>{
  '/downloads/point/last-week/left-pad': {'downloads': 2500000, 'package': 'left-pad'},
  '/downloads/point/last-week/tiny-thing': {'downloads': 12, 'package': 'tiny-thing'},
  '/tiny-thing': {
    'dist-tags': {'latest': '1.0.0'},
    'time': {'created': '2026-11-01T10:00:00.000Z'},
    'versions': {
      '1.0.0': {
        'scripts': {'postinstall': 'node x.js'},
      },
    },
  },
  '/pypi/reqests/json': {
    'releases': {
      '0.1': [
        {'upload_time_iso_8601': '2026-10-20T00:00:00Z'},
      ],
      '0.0.1': [
        {'upload_time_iso_8601': '2026-10-19T00:00:00Z'},
      ],
    },
  },
  '/api/v1/crates/serde-thing': {
    'crate': {'created_at': '2019-01-01T00:00:00Z', 'recent_downloads': 300},
  },
  '/api/v1/gems/railz.json': {'downloads': 77},
  '/api/packages/fancy_pkg': {
    'versions': [
      {'published': '2025-01-02T00:00:00Z'},
      {'published': '2024-05-06T00:00:00Z'},
    ],
  },
  '/github.com/acme/tool/@latest': {'Version': 'v1.0.0'},
};

void main() {
  group('RegistryLookup', () {
    late List<Uri> asked;
    late Object? Function(http.Request) override;
    late RegistryLookup lookup;
    late DateTime now;

    setUp(() {
      asked = [];
      override = (_) => null;
      now = DateTime.utc(2026, 11, 5);
      lookup = RegistryLookup(
        clock: () => now,
        MockClient((req) async {
          asked.add(req.url);
          if (override(req) case final Object o) {
            if (o is http.Response) return o;
            throw o;
          }
          final body = _fixtures[req.url.path];
          return body == null ? http.Response('{"error":"not found"}', 404) : http.Response(jsonEncode(body), 200);
        }),
      );
    });

    test('npm: a popular package needs only the download count', () async {
      final info = await lookup.info(const PackageRef(Ecosystem.npm, 'left-pad'));
      expect(info!.exists, isTrue);
      expect(info.downloads, 2500000);
      expect(asked.map((u) => u.host), ['api.npmjs.org']);
    });

    test('npm: a little-used package gets its packument (age, install script)', () async {
      final info = await lookup.info(const PackageRef(Ecosystem.npm, 'tiny-thing'));
      expect(info!.downloads, 12);
      expect(info.created, DateTime.utc(2026, 11, 1, 10));
      expect(info.installScript, isTrue);
      expect(asked.map((u) => u.host), ['api.npmjs.org', 'registry.npmjs.org']);
    });

    test('npm: scoped names are escaped in the registry path, 404 is missing', () async {
      final info = await lookup.info(const PackageRef(Ecosystem.npm, '@acme/nope'));
      expect(info!.exists, isFalse);
      expect(asked.last.toString(), 'https://registry.npmjs.org/@acme%2Fnope');
    });

    test('PyPI, crates.io, RubyGems, pub.dev and Go', () async {
      final py = await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests'));
      expect(py!.created, DateTime.utc(2026, 10, 19));
      final crate = await lookup.info(const PackageRef(Ecosystem.crates, 'serde-thing'));
      expect(crate!.downloads, 300);
      expect(crate.created, DateTime.utc(2019));
      expect((await lookup.info(const PackageRef(Ecosystem.gems, 'railz')))!.downloads, 77);
      expect((await lookup.info(const PackageRef(Ecosystem.pub, 'fancy_pkg')))!.created, DateTime.utc(2024, 5, 6));
      expect((await lookup.info(const PackageRef(Ecosystem.go, 'github.com/acme/tool/cmd/x')))!.exists, isTrue);
      expect((await lookup.info(const PackageRef(Ecosystem.go, 'github.com/acme/none')))!.exists, isFalse);
      expect((await lookup.info(const PackageRef(Ecosystem.pypi, 'nope')))!.exists, isFalse);
    });

    test('failures are unknown and not cached; answers are cached', () async {
      for (final failure in [http.ClientException('offline'), TimeoutException('slow'), http.Response('busy', 503)]) {
        override = (_) => failure;
        expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')), isNull);
        now = now.add(lookup.downFor);
      }
      override = (_) => null;
      expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')), isNotNull);
      final before = asked.length;
      expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')), isNotNull);
      expect(asked.length, before);
    });

    test('a registry that failed is skipped for a while, the others are not', () async {
      override = (_) => http.ClientException('dropped');
      expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')), isNull);
      override = (_) => null;
      final before = asked.length;
      expect(await lookup.info(const PackageRef(Ecosystem.pypi, 'other')), isNull);
      expect(asked.length, before);
      expect(await lookup.info(const PackageRef(Ecosystem.npm, 'left-pad')), isNotNull);
      now = now.add(lookup.downFor);
      expect((await lookup.info(const PackageRef(Ecosystem.pypi, 'reqests')))!.exists, isTrue);
    });
  });

  group('PackageGuard', () {
    test('popular and known names are not looked up; a failed lookup is a note', () async {
      final fake = _FakeLookup({});
      final guard = PackageGuard(fake, env: const {});
      final check = await guard.check('npm i react lodash tiny-x', cwd: '/nonexistent', root: '/nonexistent');
      expect(fake.asked, ['npm:tiny-x']);
      expect(check.refusal, isNull);
      expect(check.notes.single, contains("Couldn't check `tiny-x`"));
    });

    test('index settings come from the environment it is given (the login shell\'s)', () async {
      final fake = _FakeLookup({'pypi:corp-utils': PackageInfo.missing});
      final public = await PackageGuard(fake, env: const {}).check('pip install corp-utils', cwd: '/x', root: '/x');
      expect(public.refusal, contains("doesn't exist on PyPI"));
      final guard = PackageGuard(fake, loadEnv: () async => {'PIP_INDEX_URL': 'https://pypi.corp/simple'});
      final private = await guard.check('pip install corp-utils', cwd: '/x', root: '/x');
      expect(private.refusal, isNull);
      expect(private.notes.single, contains('private index'));
    });

    test('the refusal does not point at a way around the check', () async {
      final check = await PackageGuard(
        _FakeLookup({'npm:react-form-hooks-utils': PackageInfo.missing}),
        env: const {},
      ).check('npm i react-form-hooks-utils', cwd: '/x', root: '/x');
      expect(check.refusal, contains('Terminal pane'));
      expect(check.refusal, isNot(contains('manifest')));
    });
  });

  group('ToolRunner bash with the package check', () {
    late Directory tmp;
    late SessionShell shell;
    late ToolRunner runner;
    late _FakeLookup fake;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('everyai-pkg');
      Directory('${tmp.path}/bin').createSync();
      // A stand-in npm: records that it ran and, when asked, writes a lockfile.
      File('${tmp.path}/bin/npm')
          .writeAsStringSync('#!/bin/sh\ntouch ran\n[ -f lock.next ] && cp lock.next package-lock.json\nexit 0\n');
      Process.runSync('chmod', ['+x', '${tmp.path}/bin/npm']);
      fake = _FakeLookup({
        'npm:lodahs': PackageInfo.missing,
        'npm:fresh-thing': PackageInfo(created: DateTime.now().subtract(const Duration(days: 2)), downloads: 3),
        'npm:old-thing': PackageInfo(created: DateTime.utc(2018), downloads: 50000),
      });
      shell = SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh');
      runner = ToolRunner(
        root: tmp.path,
        shell: shell,
        gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: 'sk-eai-test-key-000000'),
        sessionTag: 't',
        packages: PackageGuard(fake, env: const {}),
      );
    });
    tearDown(() async {
      await shell.killAll();
      tmp.deleteSync(recursive: true);
    });

    String npm(String args) => 'PATH=${tmp.path}/bin:/usr/bin:/bin npm $args';

    test('a made-up name is refused and never reaches the shell, in Bypass too', () async {
      for (final bypass in [false, true]) {
        runner.bypass = bypass;
        final out = await runner.run('bash', {'command': 'touch marker && ${npm('i lodahs')}'});
        expect(out.isError, isTrue);
        expect(out.text, contains("`lodahs` doesn't exist on npm. Did you mean `lodash`?"));
        expect(File('${tmp.path}/marker').existsSync(), isFalse);
        expect(File('${tmp.path}/ran').existsSync(), isFalse);
      }
    });

    test('a new package installs with a note', () async {
      final out = await runner.run('bash', {'command': npm('i fresh-thing')});
      expect(out.isError, isFalse, reason: out.text);
      expect(File('${tmp.path}/ran').existsSync(), isTrue);
      expect(out.text, contains('[EveryAI package check] `fresh-thing` is new (first published 2 days ago'));
    });

    test('lockfile lines off the registry or over http, and new install scripts, are noted', () async {
      File('${tmp.path}/lock.next').writeAsStringSync(
        jsonEncode({
          'packages': {
            'node_modules/old-thing': {'resolved': 'http://evil.example/old-thing-1.0.0.tgz'},
            'node_modules/esbuild': {'resolved': 'https://mirror.example.net/esbuild.tgz', 'hasInstallScript': true},
          },
        }).replaceAll(',', ',\n'),
      );
      final out = await runner.run('bash', {'command': npm('i old-thing')});
      expect(out.text, contains('over plain http from evil.example'));
      expect(out.text, contains('downloads from mirror.example.net, not the registry'));
      expect(out.text, contains('New packages that run install scripts: esbuild.'));
      expect(out.text, isNot(contains('runs no package manager')));
    });

    test('commands that run no install leave the lockfiles alone (git checkout may change them)', () async {
      File('${tmp.path}/lock.next')
          .writeAsStringSync('{"packages": {"node_modules/x": {"resolved": "http://evil.example/x.tgz"}}}\n');
      final out = await runner.run('bash', {'command': 'cp lock.next package-lock.json'});
      expect(out.text, isNot(contains('package check')));
      expect(await runner.packages!.snapshot(tmp.path, tmp.path, installsIn('npm test')), isEmpty);
    });

    test('an install the check refuses is refused before it is shown for approval', () async {
      expect(await runner.packageRefusal('bash', {'command': npm('i lodahs')}), contains("`lodahs` doesn't exist"));
      expect(await runner.packageRefusal('bash', {'command': npm('i old-thing')}), isNull);
      expect(await runner.packageRefusal('read', {'path': 'x'}), isNull);
      expect(File('${tmp.path}/ran').existsSync(), isFalse);
    });
  });
}

final class _FakeLookup implements PackageLookup {
  _FakeLookup(this.answers);

  final Map<String, PackageInfo?> answers;
  final asked = <String>[];

  @override
  Future<PackageInfo?> info(PackageRef p) async {
    asked.add(p.key);
    return answers[p.key];
  }
}
