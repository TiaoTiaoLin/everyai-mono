// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/updates/data/install.dart';
import 'package:every_ai/features/updates/data/sparkle_bridge.dart';
import 'package:every_ai/features/updates/domain/releases.dart';
import 'package:every_ai/features/updates/update_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ReleaseVersion v(String s) => ReleaseVersion.tryParse(s)!;

Map<String, Object?> _release(String tag, {bool pre = false, bool draft = false, List<String> files = const []}) => {
  'tag_name': tag,
  'prerelease': pre,
  'draft': draft,
  'html_url': 'https://github.com/x/y/releases/tag/$tag',
  'body': 'notes',
  'assets': [
    for (final f in files) {'name': f, 'browser_download_url': 'https://dl/$tag/$f', 'size': 10},
  ],
};

/// Signed by a throwaway key with `packaging/updates.py` (keygen, then sign a file holding [_sums]).
const _testKey = 'Ws6PXXn6eoX0y5rg1ChtoUM3rpXqWZflow4HdUARNNY=';
const _sums = 'abc  EveryAI-0.2.0-x86_64.AppImage\n';
const _sumsSig = 'ILwwb/SFZJ98uUa4Xo1Yi/F5X9CXJSs6W1rO064PxnfkwMzWg4gap/wmwVjo5ZJmp9Y8O8zcUIiWw2d+PFKcAw==';

void main() {
  group('versions', () {
    test('semver order, pre-releases before their release', () {
      final ordered = [
        '0.1.0-alpha.1',
        '0.1.0-alpha.2',
        '0.1.0-alpha.10',
        '0.1.0-beta',
        '0.1.0-beta.1',
        '0.1.0-rc.1',
        '0.1.0',
        '0.1.1',
        '0.2.0-alpha.1',
        '1.0.0',
      ].map(v).toList();
      for (var i = 1; i < ordered.length; i++) {
        expect(ordered[i] > ordered[i - 1], isTrue, reason: '${ordered[i]} > ${ordered[i - 1]}');
      }
      expect(v('v0.1.0-alpha.1+7'), v('0.1.0-alpha.1'));
      expect(v('1.2'), v('1.2.0'));
      expect(ReleaseVersion.tryParse('latest'), isNull);
      expect(ReleaseVersion.tryParse('1.x'), isNull);
    });

    test('picks the newest release the channel allows', () {
      final releases = [
        _release('v0.1.0-alpha.1'),
        _release('v0.1.0-alpha.2'),
        _release('v0.2.0-beta.1', pre: true),
        _release('v9.0.0', draft: true),
      ].map(Release.fromJson).whereType<Release>().toList();
      expect(releases, hasLength(3), reason: 'drafts never count');
      expect(pickUpdate(releases, v('0.1.0-alpha.1'), prereleases: false)?.tag, 'v0.1.0-alpha.2');
      expect(pickUpdate(releases, v('0.1.0-alpha.1'), prereleases: true)?.tag, 'v0.2.0-beta.1');
      expect(pickUpdate(releases, v('0.1.0-alpha.2'), prereleases: false), isNull);
    });

    test('checksums and their signature', () async {
      expect(checksumFor('${'a' * 64}  x.deb\n${'B' * 64} *EveryAI.AppImage', 'EveryAI.AppImage'), 'b' * 64);
      expect(checksumFor('${'a' * 64}  x.deb', 'y'), isNull);
      // A signature made by packaging/updates.py verifies here: the CI signer and the app agree.
      expect(await verifySigned(_sums, _sumsSig, publicKey: _testKey), isTrue);
      expect(await verifySigned('${_sums}tampered', _sumsSig, publicKey: _testKey), isFalse);
      expect(await verifySigned(_sums, 'not base64!', publicKey: _testKey), isFalse);
    });
  });

  group('controller', () {
    late List<String> requested;

    ProviderContainer container({
      required InstallKind kind,
      required Object releases,
      Map<String, String> prefs = const {},
      SparkleBridge? sparkle,
      Future<void> Function(Release, {required http.Client client, void Function(double)? onProgress})? stage,
    }) {
      requested = [];
      final c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences.inMemory({...prefs})),
          updateEnvProvider.overrideWithValue(
            UpdateEnv(
              detect: (_) async => kind,
              current: v('0.1.0-alpha.1'),
              sparkle: sparkle,
              client: () => MockClient((req) async {
                requested.add(req.url.toString());
                return http.Response(jsonEncode(releases), 200);
              }),
              stage: stage ?? (r, {required client, onProgress}) async => onProgress?.call(1),
              restartImage: () async {},
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('an AppImage downloads the update and waits for a restart', () async {
      final c = container(
        kind: InstallKind.appImage,
        releases: _release(
          'v0.1.0-alpha.2',
          files: ['EveryAI-0.1.0-alpha.2-x86_64.AppImage', 'SHA256SUMS', 'SHA256SUMS.sig'],
        ),
      );
      await c.read(updateProvider.notifier).check();
      final s = c.read(updateProvider);
      expect(s.phase, UpdatePhase.ready);
      expect(s.showBanner, isTrue);
      expect(requested.single, endsWith('/releases/latest'), reason: 'stable channel asks for the latest only');
      c.read(updateProvider.notifier).later();
      expect(c.read(updateProvider).showBanner, isFalse);
    });

    test('a .deb, or a release without update files, offers the download', () async {
      final c = container(
        kind: InstallKind.deb,
        releases: _release('v0.1.0-alpha.2', files: ['everyai_0.1.0-alpha.2_amd64.deb']),
      );
      await c.read(updateProvider.notifier).check();
      expect(c.read(updateProvider).phase, UpdatePhase.manual);
      expect(c.read(updateProvider.notifier).manualUrl, 'https://dl/v0.1.0-alpha.2/everyai_0.1.0-alpha.2_amd64.deb');

      final unsigned = container(
        kind: InstallKind.appImage,
        releases: _release('v0.1.0-alpha.2', files: ['a.AppImage']),
      );
      await unsigned.read(updateProvider.notifier).check();
      expect(unsigned.read(updateProvider).phase, UpdatePhase.manual);
    });

    test('pre-releases come only with the setting on', () async {
      final list = [
        _release('v0.1.0-alpha.1'),
        _release('v0.2.0-beta.1', pre: true, files: ['x.deb']),
      ];
      final c = container(kind: InstallKind.deb, releases: list, prefs: {prereleasesPref: '1'});
      await c.read(updateProvider.notifier).check();
      expect(requested.single, contains('/releases?per_page='));
      expect(c.read(updateProvider).release?.tag, 'v0.2.0-beta.1');

      final stable = container(kind: InstallKind.deb, releases: list.first);
      await stable.read(updateProvider.notifier).check();
      expect(stable.read(updateProvider).phase, UpdatePhase.upToDate);
    });

    test('a failed verification shows as failed and touches nothing', () async {
      final c = container(
        kind: InstallKind.appImage,
        releases: _release('v0.1.0-alpha.2', files: ['a.AppImage', 'SHA256SUMS', 'SHA256SUMS.sig']),
        stage: (r, {required client, onProgress}) async =>
            throw const UpdateError("The release's checksums aren't signed by EveryAI."),
      );
      await c.read(updateProvider.notifier).check();
      expect(c.read(updateProvider).phase, UpdatePhase.failed);
      expect(c.read(updateProvider).error, contains('signed'));
      expect(c.read(updateProvider).showBanner, isFalse);
    });

    test('dev and store installs never ask GitHub', () async {
      final c = container(kind: InstallKind.none, releases: _release('v9.0.0'));
      await c.read(updateProvider.notifier).check();
      expect(requested, isEmpty);
      expect(c.read(updateProvider).supported, isFalse);
    });

    testWidgets('Sparkle gets the release appcast and reports ready', (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('everyai/updater-test');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final bridge = SparkleBridge(channel);
      late ProviderContainer c;
      await tester.runAsync(() async {
        c = container(
          kind: InstallKind.sparkle,
          sparkle: bridge,
          releases: _release('v0.1.0-alpha.2', files: ['EveryAI-0.1.0-alpha.2.dmg', 'appcast.xml']),
        );
        await c.read(updateProvider.notifier).check();
      });
      expect(c.read(updateProvider).phase, UpdatePhase.downloading);
      expect(calls.single.method, 'check');
      expect((calls.single.arguments as Map)['feed'], 'https://dl/v0.1.0-alpha.2/appcast.xml');

      // The native side reports the download verified and held.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('ready', {'version': '0.1.0-alpha.2'})),
        (_) {},
      );
      await tester.pump();
      expect(c.read(updateProvider).phase, UpdatePhase.ready);
      await c.read(updateProvider.notifier).restart();
      expect(calls.last.method, 'installNow');
    });
  });
}
