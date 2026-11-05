// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Layout sweep: every screen and settings section, in every design language, at a wide, a medium, a narrow and a
// short window, with normal and large text. Any overflow, unbounded size or layout exception fails the test, and the
// failure lists every one (screen, language, size, text scale, the error's first line), not just the first.

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/artifacts/ui/artifacts_screen.dart';
import 'package:every_ai/features/chat/ui/chat_screen.dart';
import 'package:every_ai/features/code/ui/code_home.dart';
import 'package:every_ai/features/history/ui/sidebar.dart';
import 'package:every_ai/features/onboarding/ui/onboarding_screen.dart';
import 'package:every_ai/features/settings/ui/settings_modal.dart';
import 'package:every_ai/features/history/ui/chats_screen.dart';
import 'package:every_ai/features/history/ui/coming_soon_screen.dart';
import 'package:every_ai/features/history/ui/projects_screen.dart';
import 'package:every_ai/features/models/ui/models_screen.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/core/ui/every_icons.dart';
import 'package:every_ai/features/settings/settings_registry.dart';
import 'package:every_ai/features/settings/ui/settings_sections.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_host.dart';

final class _Store implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Window sizes in logical pixels: wide desktop, medium, narrow (the panel overlays), phone, short.
const sizes = [Size(1280, 800), Size(820, 600), Size(560, 720), Size(380, 420)];
const textScales = [1.0, 1.6];
const languages = [DesignLanguage.cupertino, DesignLanguage.macos, DesignLanguage.material, DesignLanguage.fluent];

final screens = <String, Widget Function()>{
  'Models': () => const ModelsScreen(),
  'Chats': () => const ChatsScreen(),
  'Projects': () => const ProjectsScreen(),
  'Artifacts': () => const ArtifactsScreen(),
  'Chat (new)': () => const ChatScreen(conversationId: 'new'),
  'Code home': () => const CodeHome(),
  'Onboarding': () => const OnboardingScreen(desktop: true),
  'Settings modal': () => const SettingsModal(),
  'Sidebar': () => Sidebar(location: '/chat/new', collapsed: false, onNavigate: (_) {}, onToggle: () {}),
  'Coming soon': () => const ComingSoonScreen(
    title: 'Something',
    icon: EveryIcon.info,
    message: 'A long message that explains what will come here later, long enough to wrap on a narrow window.',
  ),
  for (final s in SettingsSection.values)
    'Settings: ${s.title}': () => SettingsBodyHost(child: settingsSectionBody(s, const {})),
};

void main() {
  for (final entry in screens.entries) {
    for (final language in languages) {
      testWidgets('${entry.key} · ${language.name} lays out at every size and text scale', (tester) async {
        final problems = <String>[];
        for (final size in sizes) {
          for (final scale in textScales) {
            final where = '${entry.key} · ${language.name} · ${size.width.round()}×${size.height.round()} · ×$scale';
            final db = AppDatabase(NativeDatabase.memory());
            final container = ProviderContainer(
              overrides: [
                databaseProvider.overrideWithValue(db),
                preferencesProvider.overrideWithValue(Preferences.inMemory()),
                secretStoreProvider.overrideWithValue(_Store()),
                apiClientProvider.overrideWithValue(
                  ApiClient(
                    baseUrl: Uri.parse('http://backend/'),
                    client: MockClient((_) async => http.Response('no network in the layout sweep', 599)),
                  ),
                ),
              ],
            );
            problems.addAll(
              await sweepOne(
                tester,
                where: where,
                size: size,
                textScale: scale,
                child: UncontrolledProviderScope(
                  container: container,
                  child: LayoutHost(
                    language: language,
                    child: ShellScope(
                      sidebarVisible: size.width >= 760,
                      compact: size.width < 760,
                      toggleSidebar: () {},
                      child: entry.value(),
                    ),
                  ),
                ),
              ),
            );
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              container.dispose();
              await db.close();
            });
          }
        }
        for (final p in problems.toSet()) {
          debugPrint('LAYOUT: $p');
        }
        expect(problems.toSet().toList(), isEmpty, reason: problems.toSet().join('\n'));
      });
    }
  }
}
