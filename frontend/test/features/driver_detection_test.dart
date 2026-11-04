import 'dart:async';
import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/drivers/driver_process_io.dart' show findOnPath;
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart' show commonDirs, mergePaths;
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Fake implements HarnessDriver {
  _Fake(this.id, this.status);
  final String id;
  final Future<DriverStatus> Function() status;
  var detects = 0;

  @override
  DriverInfo get info => DriverInfo(id: id, label: id);
  @override
  Set<DriverCap> get caps => const {};
  @override
  Future<DriverStatus> detect() {
    detects++;
    return status();
  }

  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) => throw UnimplementedError();
  @override
  Future<HarnessSession> attach(String conversationId) => throw UnimplementedError();
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

ProviderContainer _container(
  Map<String, HarnessDriver> drivers, {
  Preferences? prefs,
  DriverStatuses Function()? notifier,
}) {
  final c = ProviderContainer(
    overrides: [
      driverRegistryProvider.overrideWithValue(DriverRegistry(drivers)),
      preferencesProvider.overrideWithValue(prefs ?? Preferences.inMemory()),
      if (notifier != null) driverStatusesProvider.overrideWith(notifier),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

String _cache(Map<String, DriverStatus> statuses, {DateTime? at}) => jsonEncode({
  'v': 1,
  'checkedAt': (at ?? DateTime.now()).toIso8601String(),
  'statuses': {for (final e in statuses.entries) e.key: e.value.toJson()},
});

void main() {
  group('the scan', () {
    test('installed, missing, a throw and no answer each become a status', () async {
      final never = Completer<DriverStatus>();
      final c = _container({
        'a': _Fake('a', () async => const DriverStatus(installed: true, path: '/bin/a', version: '1.2')),
        'b': _Fake('b', () async => const DriverStatus()),
        'c': _Fake('c', () async => throw StateError('broken')),
        'd': _Fake('d', () => never.future),
      }, notifier: () => DriverStatuses(timeout: Duration.zero));
      final s = await c.read(driverStatusesProvider.future);
      expect((s['a']!.installed, s['a']!.version), (true, '1.2'));
      expect(s['b']!.installed, isFalse);
      expect((s['c']!.installed, s['c']!.problem), (false, "Couldn't check: Bad state: broken"));
      expect((s['d']!.installed, s['d']!.problem), (true, noAnswerProblem));
    });

    test('checks at most four drivers at once', () async {
      final gates = [for (var i = 0; i < 6; i++) Completer<DriverStatus>()];
      var running = 0;
      var most = 0;
      final drivers = {
        for (var i = 0; i < 6; i++)
          'd$i': _Fake('d$i', () async {
            running++;
            most = running > most ? running : most;
            try {
              return await gates[i].future;
            } finally {
              running--;
            }
          }),
      };
      final c = _container(drivers);
      final done = c.read(driverStatusesProvider.future);
      await pumpEventQueue();
      expect(drivers.values.where((d) => d.detects > 0).length, 4);
      for (final g in gates) {
        g.complete(const DriverStatus(installed: true));
        await pumpEventQueue();
      }
      expect((await done).length, 6);
      expect(most, 4);
    });

    test('two refreshes at once share one check', () async {
      final gate = Completer<DriverStatus>();
      final a = _Fake('a', () => gate.future);
      final c = _container({'a': a});
      final first = c.read(driverStatusesProvider.future);
      final n = c.read(driverStatusesProvider.notifier);
      final r1 = n.refresh();
      final r2 = n.refresh();
      gate.complete(const DriverStatus(installed: true));
      await Future.wait([first, r1, r2]);
      expect(a.detects, 1);
    });

    test('reloads the login shell once per scan, not once per CLI', () async {
      var reloads = 0;
      final drivers = {
        for (var i = 0; i < 5; i++) 'd$i': _Fake('d$i', () async => const DriverStatus(installed: true)),
      };
      final c = _container(drivers, notifier: () => DriverStatuses(reloadShell: () async => reloads++));
      await c.read(driverStatusesProvider.future);
      expect(reloads, 0);
      await c.read(driverStatusesProvider.notifier).refresh(reloadShell: true);
      expect(reloads, 1);
      expect(drivers.values.every((d) => d.detects == 2), isTrue);
    });
  });

  group('the kept check', () {
    test('a status survives JSON', () {
      const s = DriverStatus(installed: true, path: '/x', version: '2', signedIn: false, problem: 'p');
      final back = DriverStatus.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect((back.installed, back.path, back.version, back.signedIn, back.problem), (true, '/x', '2', false, 'p'));
      final empty = DriverStatus.fromJson(const {});
      expect((empty.installed, empty.signedIn), (false, null));
    });

    test('shows at once, refreshes in the background, and drops drivers no longer listed', () async {
      final at = DateTime.now().subtract(const Duration(hours: 1));
      final prefs = Preferences.inMemory({
        harnessStatusesKey: _cache({
          'a': const DriverStatus(installed: true, version: 'old'),
          'gone': const DriverStatus(installed: true),
        }, at: at),
      });
      final gate = Completer<DriverStatus>();
      final a = _Fake('a', () => gate.future);
      final c = _container({'a': a}, prefs: prefs);
      final first = await c.read(driverStatusesProvider.future);
      expect(first.keys, ['a']);
      expect(first['a']!.version, 'old');
      expect(c.read(driverStatusesProvider.notifier).checkedAt, at);
      await pumpEventQueue();
      expect(a.detects, 1); // the background refresh started
      gate.complete(const DriverStatus(installed: true, version: 'new'));
      await pumpEventQueue();
      expect(c.read(driverStatusesProvider).value!['a']!.version, 'new');
      final kept = jsonDecode(prefs[harnessStatusesKey]!) as Map<String, Object?>;
      expect((kept['statuses']! as Map)['a'], {'installed': true, 'version': 'new'});
      expect(c.read(driverStatusesProvider.notifier).checkedAt!.isAfter(at), isTrue);
    });

    test('a check that times out keeps what was known', () async {
      final prefs = Preferences.inMemory({
        harnessStatusesKey: _cache({'a': const DriverStatus(installed: true, path: '/a', version: '3')}),
      });
      final c = _container(
        {'a': _Fake('a', () => Completer<DriverStatus>().future)},
        prefs: prefs,
        notifier: () => DriverStatuses(timeout: Duration.zero),
      );
      await c.read(driverStatusesProvider.future);
      final s = await c.read(driverStatusesProvider.notifier).refresh();
      expect((s['a']!.version, s['a']!.problem), ('3', noAnswerProblem));
    });

    test('a recent check is not repeated when the app comes back', () async {
      final prefs = Preferences.inMemory({
        harnessStatusesKey: _cache({'a': const DriverStatus(installed: true)}),
      });
      final a = _Fake('a', () async => const DriverStatus(installed: true));
      final c = _container({'a': a}, prefs: prefs);
      await c.read(driverStatusesProvider.future);
      await pumpEventQueue();
      expect(a.detects, 1);
      await c.read(driverStatusesProvider.notifier).refreshIfStale();
      expect(a.detects, 1);
      await c.read(driverStatusesProvider.notifier).refreshIfStale(age: Duration.zero);
      expect(a.detects, 2);
    });
  });

  group('finding a CLI without a process', () {
    test('the first directory with the file wins; directories and missing commands are skipped', () {
      final files = {'/b/tool', '/c/tool'};
      bool isFile(String p) => files.contains(p);
      expect(findOnPath('tool', '/a:/b:/c', windows: false, isFile: isFile), '/b/tool');
      expect(findOnPath('tool', '/a:/b/', windows: false, isFile: (p) => p == '/b/tool'), '/b/tool');
      expect(findOnPath('none', '/a:/b:/c', windows: false, isFile: isFile), isNull);
      expect(findOnPath('/c/tool', '', windows: false, isFile: isFile), '/c/tool');
      expect(findOnPath('tool', '', windows: false, isFile: isFile), isNull);
    });

    test('on Windows each PATHEXT extension is tried', () {
      final files = {r'C:\npm\claude.CMD'};
      expect(
        findOnPath('claude', r'C:\bin;C:\npm', windows: true, pathExt: '.EXE;.CMD', isFile: files.contains),
        r'C:\npm\claude.CMD',
      );
    });

    test('the usual install directories, only the ones that exist', () {
      final dirs = {
        '/opt/homebrew/bin',
        '/h/.bun/bin',
        '/h/.npm-pkgs/bin',
        '/h/.nvm/versions/node/v18.2.0/bin',
        '/h/.nvm/versions/node/v20.11.1/bin',
        '/h/.nvm/versions/node/v9.0.0/bin',
      };
      final files = {'/h/.npmrc': 'color=true\nprefix = ~/.npm-pkgs\n'};
      List<String> list(String d) => d == '/h/.nvm/versions/node' ? ['v9.0.0', 'v18.2.0', 'v20.11.1', 'junk'] : [];
      final found = commonDirs('/h', const {}, exists: dirs.contains, read: (f) => files[f], list: list);
      expect(found, ['/opt/homebrew/bin', '/h/.npm-pkgs/bin', '/h/.nvm/versions/node/v20.11.1/bin', '/h/.bun/bin']);
      // nvm's default alias wins over the newest version.
      files['/h/.nvm/alias/default'] = '18.2.0\n';
      expect(
        commonDirs('/h', const {}, exists: dirs.contains, read: (f) => files[f], list: list),
        contains('/h/.nvm/versions/node/v18.2.0/bin'),
      );
      // NPM_CONFIG_PREFIX wins over .npmrc.
      dirs.add('/p/bin');
      expect(
        commonDirs('/h', const {'NPM_CONFIG_PREFIX': '/p'}, exists: dirs.contains, read: (f) => files[f], list: list),
        contains('/p/bin'),
      );
    });

    test('Windows install directories', () {
      final found = commonDirs(
        r'C:\Users\u',
        const {'APPDATA': r'C:\AppData', 'USERPROFILE': r'C:\Users\u'},
        windows: true,
        exists: (d) => d != r'C:\Users\u\scoop\shims',
      );
      expect(found, [r'C:\AppData\npm', r'C:\Users\u\.local\bin', r'C:\Users\u\.bun\bin']);
    });

    test('the login PATH comes first and each directory appears once', () {
      expect(mergePaths('/a:/b:/a', ['/b', '/c', '/a', '/d']), '/a:/b:/c:/d');
      expect(mergePaths(r'C:\A;c:\b', [r'C:\B', r'C:\C'], windows: true), r'C:\A;c:\b;C:\C');
    });
  });

  group('the lead picker', () {
    const plain = DriverInfo(id: 'codex', label: 'Codex');
    const paid = DriverInfo(id: 'claude-code', label: 'Claude Code', needsConsent: true);

    test('offers EveryAI, the current pick and installed harnesses only', () {
      const everyai = DriverInfo(id: 'everyai', label: 'EveryAI');
      expect(offeredAsLead(everyai, null, current: 'everyai'), isTrue);
      expect(offeredAsLead(plain, null, current: 'everyai'), isFalse);
      expect(offeredAsLead(plain, const DriverStatus(), current: 'everyai'), isFalse);
      expect(offeredAsLead(plain, const DriverStatus(), current: 'codex'), isTrue);
      expect(offeredAsLead(plain, const DriverStatus(installed: true, signedIn: false), current: 'everyai'), isTrue);
    });

    test('a greyed harness says how to fix it', () {
      String? f(DriverInfo i, DriverStatus? s, {bool consented = false}) => leadFix(i, s, consented: consented);
      expect(f(plain, const DriverStatus(installed: true)), isNull);
      expect(
        f(plain, const DriverStatus(installed: true, signedIn: false, problem: 'Not signed in. Run `x login`.')),
        'Not signed in. Run `x login`.',
      );
      expect(f(plain, const DriverStatus(installed: true, signedIn: false)), 'Not signed in');
      expect(f(paid, const DriverStatus(installed: true, signedIn: true)), 'Turn on in Settings → Code → Harnesses');
      expect(f(plain, const DriverStatus(installed: true, problem: notBuiltProblem)), 'Not built yet in this version');
      expect(f(plain, const DriverStatus(installed: true, problem: noAnswerProblem)), '$noAnswerProblem Check again.');
      expect(f(plain, const DriverStatus()), 'Not installed');
      expect(f(plain, const DriverStatus(installed: true, problem: 'Too old')), 'Too old');
    });
  });
}
