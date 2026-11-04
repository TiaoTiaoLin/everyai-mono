import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/code_providers.dart' show harnessProvider;
import 'package:every_ai/features/code/drivers/acp/acp_agents.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/registry_install/acp_registry.dart';
import 'package:every_ai/features/code/drivers/registry_install/installed_agents.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _fixture = File('test/fixtures/drivers/acp_registry/registry.json').readAsStringSync();

RegistryAgent _agent(String id) => parseRegistry(_fixture).firstWhere((a) => a.id == id);

/// The listed ACP entries the registry agents may share a profile with.
Map<String, HarnessDriver> get _fixed => {
  for (final (id, command) in [
    ('gemini', 'gemini'),
    ('cline', 'cline'),
    ('grok', 'grok'),
    ('kiro', 'kiro-cli'),
    ('cursor', 'cursor-agent'),
    ('antigravity', 'agy'),
  ])
    id: AcpDriver(id: id, label: id, command: command),
};

String _registry(List<Map<String, Object?>> agents) => jsonEncode({'version': '1.0.0', 'agents': agents});

Map<String, Object?> _entry(String id, Map<String, Object?> distribution) => {
  'id': id,
  'name': id,
  'version': '1.0.0',
  'description': 'd',
  'distribution': distribution,
};

Uint8List _tarGz(List<ArchiveFile> files) {
  final a = Archive();
  files.forEach(a.addFile);
  return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(a));
}

/// A zip made "on Unix" (each central entry's creator byte is 3), so its
/// modes and links are read as Unix ones.
Uint8List _zip(List<ArchiveFile> files) {
  final a = Archive();
  files.forEach(a.addFile);
  final bytes = ZipEncoder().encodeBytes(a);
  for (var i = 0; i + 6 <= bytes.length; i++) {
    if (bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x01 && bytes[i + 3] == 0x02) bytes[i + 5] = 3;
  }
  return bytes;
}

/// A tar with a hard link [name] to [target] (the encoder writes none).
Uint8List _tarHardLink(String name, String target) {
  final out = OutputMemoryStream();
  (TarFile()
        ..filename = name
        ..typeFlag = TarFile.hardLink
        ..nameOfLinkedFile = target
        ..mode = 0x1a4)
      .write(out);
  out.writeBytes(Uint8List(1024));
  return GZipEncoder().encodeBytes(out.getBytes());
}

/// A zip symlink: its target as content, with the link file type.
ArchiveFile _zipLink(String name, String target) => ArchiveFile.string(name, target)..mode = 0xA1FF;

ArchiveFile _exe(String name) => ArchiveFile.string(name, '#!/bin/sh\necho hi\n')..mode = 0x1ed;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('registry_install'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('parseRegistry', () {
    test('reads every fixture agent and its distributions', () {
      final agents = parseRegistry(_fixture);
      expect(agents, hasLength(9));
      final kiro = _agent('kiro');
      expect(kiro.name, 'Kiro CLI');
      expect(kiro.binary['darwin-aarch64']!.cmd, 'kirocli/bin/kiro-cli');
      expect(kiro.binary['darwin-aarch64']!.sha256, hasLength(64));
      expect(_agent('cursor').binary['windows-x86_64']!.cmd, 'dist-package/cursor-agent.cmd');
      expect(_agent('fast-agent').uvx!.env, {'FAST_AGENT_MODEL': 'codexplan'});
    });

    test('leaves out an entry that breaks a rule and keeps the rest', () {
      final ok = _entry('ok', {
        'npx': {'package': 'ok@1.0.0'},
      });
      final agents = parseRegistry(
        _registry([
          ok,
          _entry('http', {
            'binary': {
              'linux-x86_64': {'archive': 'http://example.com/a.tar.gz', 'cmd': './a'},
            },
          }),
          _entry('unpinned', {
            'npx': {'package': 'some-agent'},
          }),
          _entry('latest', {
            'npx': {'package': 'some-agent@latest'},
          }),
          _entry('climb', {
            'binary': {
              'linux-x86_64': {'archive': 'https://example.com/a.tar.gz', 'cmd': '../x'},
            },
          }),
          _entry('abs', {
            'binary': {
              'linux-x86_64': {'archive': 'https://example.com/a.tar.gz', 'cmd': '/bin/sh'},
            },
          }),
          _entry('../bad', {
            'npx': {'package': 'ok@1.0.0'},
          }),
          {...ok, 'id': 'badver', 'version': '..'},
        ]),
      );
      expect([for (final a in agents) a.id], ['ok']);
    });

    test('refuses a body over 1 MiB', () {
      expect(() => parseRegistry(' ' * (maxRegistryBytes + 1)), throwsFormatException);
    });
  });

  group('the registry client', () {
    final at = DateTime.utc(2026, 11, 4, 12);

    test('a fetch keeps the body with its time', () async {
      final prefs = Preferences.inMemory();
      final c = AcpRegistryClient(prefs, client: MockClient((_) async => http.Response(_fixture, 200)), now: () => at);
      final list = await c.load();
      expect(list.agents, hasLength(9));
      expect(list.note, isNull);
      final kept = jsonDecode(prefs[acpRegistryCacheKey]!) as Map<String, Object?>;
      expect((kept['v'], kept['fetchedAt'], kept['json']), (1, at.toIso8601String(), _fixture));
    });

    test('offline, the kept copy shows with a note', () async {
      final prefs = Preferences.inMemory({
        acpRegistryCacheKey: jsonEncode({'v': 1, 'fetchedAt': at.toIso8601String(), 'json': _fixture}),
      });
      final c = AcpRegistryClient(
        prefs,
        client: MockClient((_) async => throw http.ClientException('offline')),
        now: () => at.add(const Duration(hours: 3)),
      );
      final list = await c.load();
      expect(list.agents, hasLength(9));
      expect(list.note, contains('3 h ago'));
    });

    test('a fresh copy is not fetched again', () async {
      var fetches = 0;
      final prefs = Preferences.inMemory({
        acpRegistryCacheKey: jsonEncode({'v': 1, 'fetchedAt': at.toIso8601String(), 'json': _fixture}),
      });
      final c = AcpRegistryClient(
        prefs,
        client: MockClient((_) async {
          fetches++;
          return http.Response(_fixture, 200);
        }),
        now: () => at.add(const Duration(minutes: 10)),
      );
      expect((await c.load()).agents, hasLength(9));
      expect(fetches, 0);
      await c.load(force: true);
      expect(fetches, 1);
    });
  });

  group('platform pick', () {
    test('maps the OS and CPU', () {
      expect(platformKey('macos', 'arm64'), 'darwin-aarch64');
      expect(platformKey('linux', 'x64'), 'linux-x86_64');
      expect(platformKey('fuchsia', 'x64'), isNull);
    });

    test('download first, then npx, then uvx', () {
      expect(pickDistribution(_agent('kiro'), 'darwin-aarch64')!.binary!.cmd, 'kirocli/bin/kiro-cli');
      expect(pickDistribution(_agent('kilo'), 'darwin-aarch64')!.kind, DistKind.binary);
      expect(pickDistribution(_agent('kilo'), 'linux-aarch64')!.kind, DistKind.npx);
      expect(pickDistribution(_agent('gemini'), 'darwin-aarch64')!.kind, DistKind.npx);
      expect(pickDistribution(_agent('fast-agent'), 'darwin-aarch64')!.kind, DistKind.uvx);
    });

    test('Windows on ARM falls back to x86_64; nothing for this computer is null', () {
      expect(pickDistribution(_agent('kilo'), 'windows-aarch64')!.binary!.cmd, 'kilo.exe');
      expect(pickDistribution(_agent('kiro'), 'windows-x86_64'), isNull);
    });
  });

  group('binary install', () {
    final chmodded = <String>[];
    AgentInstaller installer(Uint8List body, {int maxUnpacked = 1 << 20}) => AgentInstaller(
      client: MockClient((_) async => http.Response.bytes(body, 200)),
      dataDir: () async => tmp.path,
      platform: () => 'linux-x86_64',
      makeExecutable: (p) async => chmodded.add(p),
      maxUnpacked: maxUnpacked,
    );
    RegistryAgent agent(Uint8List body, {String cmd = './bin/agent', String url = 'a.tar.gz', bool sha = true}) =>
        RegistryAgent(
          id: 'demo',
          name: 'Demo',
          version: '1.2.3',
          binary: {
            'linux-x86_64': BinaryTarget(
              archive: 'https://example.com/$url',
              cmd: normalizeCommandPath(cmd)!,
              sha256: sha ? '${sha256.convert(body)}' : null,
              args: const ['acp'],
            ),
          },
        );
    setUp(chmodded.clear);

    test('a matching checksum installs under agents/<id>/<version>/', () async {
      final body = _tarGz([_exe('bin/agent'), ArchiveFile.string('README', 'x')]);
      final rec = await installer(body).install(agent(body));
      expect(rec.exe, '${tmp.path}/agents/demo/1.2.3/bin/agent');
      expect(File(rec.exe!).existsSync(), isTrue);
      expect(chmodded.single, endsWith('/bin/agent'));
      expect((rec.kind, rec.sha256Checked), (DistKind.binary, true));
      expect(rec.args, ['acp']);
      expect(Directory('${tmp.path}/agents/demo').listSync().map((e) => e.path.split('/').last), ['1.2.3']);
    });

    test('a new version replaces the old folder', () async {
      Directory('${tmp.path}/agents/demo/1.0.0').createSync(recursive: true);
      final body = _tarGz([_exe('bin/agent')]);
      await installer(body).install(agent(body));
      expect(Directory('${tmp.path}/agents/demo').listSync().map((e) => e.path.split('/').last), ['1.2.3']);
    });

    test('a checksum mismatch is refused and leaves nothing', () async {
      final body = _tarGz([_exe('bin/agent')]);
      final wrong = agent(_tarGz([_exe('bin/other')]));
      await expectLater(
        installer(body).install(wrong),
        throwsA(isA<InstallError>().having((e) => e.message, 'message', contains("didn't match its checksum"))),
      );
      expect(Directory('${tmp.path}/agents/demo').listSync(), isEmpty);
      expect(chmodded, isEmpty);
    });

    test('without a checksum it installs only when allowed', () async {
      final body = _tarGz([_exe('bin/agent')]);
      final a = agent(body, sha: false);
      await expectLater(installer(body).install(a), throwsA(isA<InstallError>()));
      expect(Directory('${tmp.path}/agents').existsSync(), isFalse);
      final rec = await installer(body).install(a, allowUnchecked: true);
      expect((File(rec.exe!).existsSync(), rec.sha256Checked), (true, false));
    });

    for (final (what, body) in [
      ('a tar entry ../evil', () => _tarGz([_exe('bin/agent'), ArchiveFile.string('../evil', 'x')])),
      ('a tar entry /abs', () => _tarGz([_exe('bin/agent'), ArchiveFile.string('/abs', 'x')])),
      ('a tar symlink to /etc', () => _tarGz([_exe('bin/agent'), ArchiveFile.symlink('l', '/etc')])),
      ('a tar symlink ../../x', () => _tarGz([_exe('bin/agent'), ArchiveFile.symlink('bin/l', '../../x')])),
      ('a tar hard link out', () => _tarHardLink('bin/agent', '../outside')),
      ('a zip entry ../evil', () => _zip([_exe('bin/agent'), ArchiveFile.string('../evil', 'x')])),
      ('a zip symlink out', () => _zip([_exe('bin/agent'), _zipLink('l', '../../etc/passwd')])),
    ]) {
      test('$what is refused and leaves nothing', () async {
        final bytes = body();
        final url = what.contains('zip') ? 'a.zip' : 'a.tar.gz';
        await expectLater(
          installer(bytes).install(agent(bytes, url: url)),
          throwsA(isA<InstallError>().having((e) => e.message, 'message', contains('outside its folder'))),
        );
        expect(Directory('${tmp.path}/agents/demo').listSync(), isEmpty);
        expect(File('${tmp.path}/evil').existsSync(), isFalse);
        expect(chmodded, isEmpty);
      });
    }

    test('unpacking past the size cap is refused', () async {
      final bytes = _tarGz([_exe('bin/agent'), ArchiveFile.bytes('big', Uint8List(4096))]);
      await expectLater(installer(bytes, maxUnpacked: 1024).install(agent(bytes)), throwsA(isA<InstallError>()));
      expect(Directory('${tmp.path}/agents/demo').listSync(), isEmpty);
    });

    test('an inner symlink is kept', () async {
      final bytes = _tarGz([_exe('lib/agent'), ArchiveFile.symlink('bin/agent', '../lib/agent')]);
      final rec = await installer(bytes).install(agent(bytes));
      expect(FileSystemEntity.isLinkSync(rec.exe!), isTrue);
      expect(chmodded.single, endsWith('/lib/agent'));
    });

    test('a bare program goes to the command path', () async {
      final bytes = Uint8List.fromList(utf8.encode('#!/bin/sh\n'));
      final rec = await installer(bytes).install(agent(bytes, url: 'sigit-linux', cmd: './sigit'));
      expect(rec.exe, '${tmp.path}/agents/demo/1.2.3/sigit');
      expect(File(rec.exe!).readAsStringSync(), '#!/bin/sh\n');
    });

    test('an archive without the command says so', () async {
      final bytes = _tarGz([_exe('bin/other')]);
      await expectLater(
        installer(bytes).install(agent(bytes)),
        throwsA(isA<InstallError>().having((e) => e.message, 'message', contains("didn't contain bin/agent"))),
      );
    });

    test('Remove deletes the folder', () async {
      final body = _tarGz([_exe('bin/agent')]);
      final i = installer(body);
      await i.install(agent(body));
      await i.remove('demo');
      expect(Directory('${tmp.path}/agents/demo').existsSync(), isFalse);
    });

    test('npx and uvx agents are recorded, not fetched', () async {
      var fetched = false;
      final i = AgentInstaller(
        client: MockClient((_) async {
          fetched = true;
          return http.Response('', 200);
        }),
        dataDir: () async => tmp.path,
        platform: () => 'darwin-aarch64',
      );
      final rec = await i.install(_agent('gemini'));
      expect((rec.kind, rec.package, rec.exe), (DistKind.npx, '@google/gemini-cli@0.66.0', null));
      expect(fetched, isFalse);
      expect(Directory('${tmp.path}/agents').existsSync(), isFalse);
    });
  });

  group('command lines', () {
    InstalledAgent rec(String id, {String platform = 'darwin-aarch64', String? exe}) {
      final a = _agent(id);
      final d = pickDistribution(a, platform)!;
      return InstalledAgent(
        id: a.id,
        name: a.name,
        version: a.version,
        kind: d.kind,
        exe: exe,
        package: d.run?.package,
        args: d.args,
        env: d.env,
      );
    }

    List<String> line(AcpDriver d) => [d.resolved.executable, ...d.resolved.args];

    test('gemini through npx keeps its asking flags', () {
      expect(line(registryDriver(rec('gemini'), _fixed)), [
        'npx',
        '-y',
        '@google/gemini-cli@0.66.0',
        '--acp',
        '--approval-mode',
        'default',
      ]);
    });

    test('grok-build runs on the grok profile', () {
      final d = registryDriver(rec('grok-build'), _fixed);
      expect(line(d), [
        'npx',
        '-y',
        '@xai-official/grok@1.0.74',
        '--permission-mode',
        'default',
        '--no-auto-update',
        'agent',
        'stdio',
      ]);
      expect(d.resolved.profile.agent, AcpAgent.grok);
      expect(d.info.consentId, 'grok');
    });

    test('fast-agent through uvx with its env', () {
      final d = registryDriver(rec('fast-agent'), _fixed);
      expect(line(d), ['uvx', 'fast-agent-acp==0.10.1', '-x']);
      expect(d.resolved.profile.env(null), {'FAST_AGENT_MODEL': 'codexplan'});
      expect(d.initTimeout, const Duration(minutes: 5));
    });

    test('a profile env wins over the registry env', () {
      expect(acpProfileOf('goose').withEnv({'GOOSE_MODE': 'auto', 'X': '1'}).env(null), {
        'GOOSE_MODE': 'approve',
        'X': '1',
      });
    });

    test('kiro from a download runs at its path, flags not repeated', () {
      final d = registryDriver(rec('kiro', exe: '/data/agents/kiro/2.37.1/kirocli/bin/kiro-cli'), _fixed);
      expect(line(d), [
        '/data/agents/kiro/2.37.1/kirocli/bin/kiro-cli',
        'acp',
        '--agent-engine=v3',
        '--auth-method=cli',
      ]);
    });
  });

  group('runner detect', () {
    InstalledAgent rec(String id) {
      final a = _agent(id);
      final d = pickDistribution(a, 'darwin-aarch64')!;
      return InstalledAgent(id: a.id, name: a.name, version: a.version, kind: d.kind, package: d.run?.package);
    }

    Never noRun({
      required String executable,
      required List<String> args,
      required String cwd,
      required String sessionTag,
      required String logPath,
      required Map<String, String> env,
    }) => fail('nothing runs while checking');

    test('a missing runner says what to install', () async {
      Future<String?> none(String _) async => null;
      expect((await registryDriver(rec('gemini'), _fixed, which: none).detect()).problem, 'Needs Node.js');
      expect((await registryDriver(rec('fast-agent'), _fixed, which: none).detect()).problem, 'Needs uv');
    });

    test('found, it reports the registry version without running anything', () async {
      final looked = <String>[];
      final d = registryDriver(
        rec('grok-build'),
        _fixed,
        which: (c) async {
          looked.add(c);
          return '/usr/local/bin/$c';
        },
        loginEnv: () async => {'XAI_API_KEY': 'k'},
        connect: noRun,
      );
      final s = await d.detect();
      expect((s.installed, s.version, s.signedIn, s.problem), (true, '1.0.74', true, null));
      expect(looked, ['npx']);
    });

    test('without a key the sign-in is unknown, not checked by running it', () async {
      final d = registryDriver(
        rec('grok-build'),
        _fixed,
        which: (c) async => '/usr/local/bin/$c',
        loginEnv: () async => const {},
        connect: noRun,
      );
      expect((await d.detect()).signedIn, isNull);
    });
  });

  group('the driver layer', () {
    const gemini = InstalledAgent(
      id: 'gemini',
      name: 'Gemini CLI',
      version: '0.66.0',
      kind: DistKind.npx,
      package: '@google/gemini-cli@0.66.0',
    );

    test('an installed agent is listed and resolves; the listed one is untouched', () {
      final fixed = _fixed;
      final r = DriverRegistry(fixed)..setInstalled(installedDrivers({'gemini': gemini}, fixed));
      expect([for (final d in r.listed) d.info.id], [...fixed.keys, 'registry:gemini']);
      expect(r.resolve('registry:gemini'), isA<AcpDriver>());
      expect(r.resolve('gemini'), same(fixed['gemini']));
    });

    test('setInstalled keeps the instance of an unchanged record', () {
      final r = DriverRegistry(_fixed)..setInstalled(installedDrivers({'gemini': gemini}, _fixed));
      final first = r.resolve('registry:gemini');
      r.setInstalled(installedDrivers({'gemini': gemini}, _fixed));
      expect(r.resolve('registry:gemini'), same(first));
      const newer = InstalledAgent(
        id: 'gemini',
        name: 'Gemini CLI',
        version: '0.67.0',
        kind: DistKind.npx,
        package: '@google/gemini-cli@0.67.0',
      );
      r.setInstalled(installedDrivers({'gemini': newer}, _fixed));
      expect(r.resolve('registry:gemini'), isNot(same(first)));
      r.setInstalled(const {});
      expect(r.resolve('registry:gemini'), isNull);
    });

    test('the app registry lists the stored agents from its first build', () {
      final c = ProviderContainer(
        overrides: [
          harnessProvider.overrideWithValue(FakeHarness()),
          preferencesProvider.overrideWithValue(
            Preferences.inMemory({
              installedAgentsKey: jsonEncode({
                'v': 1,
                'agents': {'gemini': gemini.toJson()},
              }),
            }),
          ),
        ],
      );
      addTearDown(c.dispose);
      final r = c.read(driverRegistryProvider);
      expect(r.listed.map((d) => d.info.id), contains('registry:gemini'));
      expect(r.resolve('registry:gemini')!.info.consentId, 'gemini');
    });

    test('records survive a round trip through Preferences', () {
      final prefs = Preferences.inMemory({
        installedAgentsKey: jsonEncode({
          'v': 1,
          'agents': {'gemini': gemini.toJson(), 'broken': 'x'},
        }),
      });
      final read = readInstalledAgents(prefs);
      expect(read.keys, ['gemini']);
      expect(jsonEncode(read['gemini']!.toJson()), jsonEncode(gemini.toJson()));
    });
  });

  group('consent', () {
    DriverInfo info(String id, DistKind kind, {String? exe, String? package}) => registryDriver(
      InstalledAgent(id: id, name: id, version: '1', kind: kind, exe: exe, package: package),
      _fixed,
    ).info;

    test('follows the listed entry, the program, or asks for an unknown one', () {
      final gemini = info('gemini', DistKind.npx, package: 'g@1.0.0');
      expect((gemini.needsConsent, gemini.consentId), (true, 'gemini'));
      final cline = info('cline', DistKind.npx, package: 'cline@1.0.0');
      expect((cline.needsConsent, cline.consentId), (false, 'cline'));
      final claude = info('claude-acp', DistKind.npx, package: 'c@1.0.0');
      expect((claude.needsConsent, claude.consentId), (true, 'registry:claude-acp'));
      expect(info('opencode', DistKind.binary, exe: '/x/opencode').needsConsent, isFalse);
      final agy = info('antigravity-acp', DistKind.binary, exe: '/x/agy_acp_server.par');
      expect((agy.needsConsent, agy.consentId), (true, 'registry:antigravity-acp'));
    });
  });
}
