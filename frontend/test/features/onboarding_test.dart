import 'dart:io';

import 'package:every_ai/core/config/version.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/onboarding/onboarding_providers.dart';
import 'package:every_ai/features/onboarding/ui/onboarding_screen.dart';
import 'package:every_ai/features/settings/domain/key_check.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('the version constant matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([^+\s]+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(version, appVersion);
  });

  test('acceptance is per version: an older build\'s acceptance asks again', () {
    final old = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(Preferences.inMemory({OnboardingAccepted.key: '0.0.9'})),
      ],
    );
    addTearDown(old.dispose);
    expect(old.read(onboardingAcceptedProvider), isFalse);

    final prefs = Preferences.inMemory();
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    c.read(onboardingAcceptedProvider.notifier).accept();
    expect(c.read(onboardingAcceptedProvider), isTrue);
    expect(prefs[OnboardingAccepted.key], appVersion);
  });

  test('bug reports open a GitHub issue carrying the version', () {
    final uri = bugReportUri();
    expect(uri.host, 'github.com');
    expect(uri.path, endsWith('/issues/new'));
    expect(uri.queryParameters['body'], contains('Version: $appVersion'));
  });

  testWidgets('the tour: a rejected key isn\'t saved, a good one is, and Enter needs the box ticked', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = Preferences.inMemory();
    final store = _MemoryStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          secretStoreProvider.overrideWithValue(store),
          keyCheckProvider.overrideWithValue(
            (provider, key) async => key == 'good'
                ? (valid: true, message: '${provider.name} key works')
                : (valid: false, message: '${provider.name} rejected this key.'),
          ),
        ],
        child: m.MaterialApp(
          builder: (context, c) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
          home: const m.Material(child: OnboardingScreen(desktop: false)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text("Hi. You're early."), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding.next')));
    await tester.pumpAndSettle();
    expect(find.text('Things will break.'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding.report')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding.next')));
    await tester.pumpAndSettle();
    expect(find.text('Chat runs on your key.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('onboarding.key')), 'bad');
    await tester.tap(find.byKey(const ValueKey('onboarding.key.save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('It was not saved'), findsOneWidget);
    expect(store.values, isEmpty);

    await tester.enterText(find.byKey(const ValueKey('onboarding.key')), 'good');
    await tester.tap(find.byKey(const ValueKey('onboarding.key.save')));
    await tester.pumpAndSettle();
    expect(store.values['byok.openrouter'], 'good');

    await tester.tap(find.byKey(const ValueKey('onboarding.next')));
    await tester.pumpAndSettle();
    expect(find.text('Code runs on your computer.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding.next')));
    await tester.pumpAndSettle();
    expect(find.text('One last thing.'), findsOneWidget);

    // Enter stays off until the box is ticked.
    await tester.tap(find.byKey(const ValueKey('onboarding.enter')));
    await tester.pumpAndSettle();
    expect(prefs[OnboardingAccepted.key], isNull);

    await tester.tap(find.byKey(const ValueKey('onboarding.terms')));
    await tester.pumpAndSettle();
    expect(find.textContaining(devBuildTerms.first), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding.agree')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding.enter')));
    await tester.pumpAndSettle();
    expect(prefs[OnboardingAccepted.key], appVersion);
  });
}
