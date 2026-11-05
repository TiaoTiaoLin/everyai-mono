import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/providers.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/layout.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/segmented.dart';
import '../../agents/ui/agents_settings_screen.dart';
import '../../auth/auth_providers.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/profile.dart';
import '../../billing/ui/billing_screen.dart';
import '../../code/code_settings_providers.dart' show SettingsScope;
import '../../code/ui/code_settings_section.dart';
import '../../code/ui/mcp_settings_screen.dart';
import '../../memory/ui/memory_screen.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';
import '../../remote/ui/remote_settings_screen.dart';
import '../../skills/ui/skills_settings_screen.dart';
import '../../slash/custom/custom_commands_screen.dart';
import '../../usage/ui/usage_screen.dart';
import '../appearance.dart';
import '../dev_upstream.dart';
import '../reply_language.dart';
import '../settings_registry.dart';
import 'account_menu.dart';
import 'api_keys_section.dart';
import 'notices_screen.dart';
import 'settings_modal.dart';

/// The body of [section] in the Settings modal; [args] as `showSettings` got them.
Widget settingsSectionBody(SettingsSection section, Map<String, String> args) => switch (section) {
  SettingsSection.general => const GeneralSection(),
  SettingsSection.account => const AccountSection(),
  SettingsSection.apiKeys => const ApiKeysSection(),
  SettingsSection.billing => const BillingBody(),
  SettingsSection.usage => const UsageBody(),
  SettingsSection.models => const ModelsSection(),
  SettingsSection.memory => const MemoryBody(),
  SettingsSection.code => CodeSettingsSection(
    projectId: args['project'],
    sessionId: args['session'],
    scope: args['scope'] == null ? null : SettingsScope.parse(args['scope']),
  ),
  SettingsSection.permissions => const PermissionsSection(),
  SettingsSection.mcp => McpSettingsBody(projectId: args['project']),
  SettingsSection.skills => const SkillsSettingsBody(),
  SettingsSection.agents => const AgentsSettingsBody(),
  SettingsSection.commands => const CustomCommandsBody(),
  SettingsSection.remote => const RemoteSettingsBody(),
  SettingsSection.developer => const DeveloperSection(),
  SettingsSection.about => const AboutSection(),
};

/// A value picker: the current value, a menu of the options.
Widget settingsPicker<T>(String current, List<(String, T)> options, ValueChanged<T> onPick, {Key? key}) =>
    AdaptiveMenuButton(
      key: key,
      actions: [
        for (final (label, value) in options)
          MenuAction(label: label, checked: label == current, onSelected: () => onPick(value)),
      ],
      child: MenuTrigger(current),
    );

const _listPadding = EdgeInsets.fromLTRB(16, 8, 16, 32);

/// Preferences → General: appearance, the default chat model and the reply language.
class GeneralSection extends ConsumerWidget {
  const GeneralSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final appearanceCtl = ref.read(appearanceProvider.notifier);
    final defaultModel = ref.watch(defaultModelProvider);
    final library = ref.watch(libraryProvider).value ?? const [];
    final language = ref.watch(replyLanguageProvider);
    const s = SettingsSection.general;
    return ListView(
      padding: _listPadding,
      children: [
        const AdaptiveSectionHeader('Appearance'),
        SettingsAnchor(
          section: s,
          id: 'theme',
          child: AdaptiveListTile(
            title: const Text('Theme'),
            trailing: AdaptiveSegmented<ThemePreference>(
              key: const ValueKey('settings.theme'),
              values: ThemePreference.values,
              selected: appearance.theme,
              label: (_) => '',
              semanticLabel: (t) => t.label,
              icon: (t) => switch (t) {
                ThemePreference.system => EveryIcon.display,
                ThemePreference.light => EveryIcon.sun,
                ThemePreference.dark => EveryIcon.moon,
              },
              onSelected: appearanceCtl.setTheme,
            ),
          ),
        ),
        SettingsAnchor(
          section: s,
          id: 'design',
          child: AdaptiveListTile(
            title: const Text('Design'),
            subtitle: Text('Follows this device by default (${DesignLanguage.host.label}).'),
            trailing: settingsPicker<DesignLanguage?>(appearance.designOverride?.label ?? 'Automatic', [
              ('Automatic', null),
              for (final d in DesignLanguage.values) (d.label, d),
            ], appearanceCtl.setDesign),
          ),
        ),
        const AdaptiveSectionHeader('Chat'),
        SettingsAnchor(
          section: s,
          id: 'default-model',
          child: AdaptiveListTile(
            title: const Text('Default model'),
            trailing: settingsPicker(defaultModel.name, [
              for (final m in {...library, defaultModel}) (m.name, m),
            ], ref.read(defaultModelProvider.notifier).set),
          ),
        ),
        SettingsAnchor(
          section: s,
          id: 'language',
          child: AdaptiveListTile(
            title: const Text('Reply language'),
            subtitle: const Text('Chat answers and suggested follow-ups. The app itself stays in English.'),
            trailing: settingsPicker(
              key: const ValueKey('settings.language'),
              language == ReplyLanguage.auto ? 'Same as my message' : language,
              [('Same as my message', ReplyLanguage.auto), for (final l in replyLanguages) (l, l)],
              ref.read(replyLanguageProvider.notifier).set,
            ),
          ),
        ),
      ],
    );
  }
}

/// Preferences → Account: who is signed in, and signing out.
class AccountSection extends ConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final auth = ref.watch(authProvider);
    final profile = ref.watch(profileProvider).value;
    final (name, plan) = accountSummary(auth, profile);
    return ListView(
      padding: _listPadding,
      children: [
        AdaptiveListTile(
          leading: AccountAvatar(name: name, size: 40),
          title: Text(name),
          subtitle: Text(plan.isEmpty ? 'Not signed in' : plan),
        ),
        if (profile != null && profile.email.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(profile.email, style: theme.type.caption.tint(theme.textMuted)),
          ),
        SettingsAnchor(
          section: SettingsSection.account,
          id: 'sign-out',
          child: switch (auth) {
            Bypassed() => const AdaptiveListTile(
              title: Text('Signed out (development mode)'),
              subtitle: Text('Sign-in is skipped while DEV_SKIP_AUTH is on.'),
            ),
            SignedIn() => AdaptiveListTile(
              title: const Text('Log out of this device'),
              subtitle: const Text('Chats stay on this device.'),
              trailing: AdaptiveButton(
                key: const ValueKey('settings.sign-out'),
                label: 'Log out',
                emphasis: ButtonEmphasis.destructive,
                onPressed: () => confirmSignOut(context, ref),
              ),
            ),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }
}

/// Preferences → Models: My models, and a way to the shop.
class ModelsSection extends ConsumerWidget {
  const ModelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final library = ref.watch(libraryProvider).value ?? const [];
    return ListView(
      padding: _listPadding,
      children: [
        WrapRow(
          lead: Text(
            'The models in your pickers. Add more from the shop.',
            style: theme.type.callout.tint(theme.textMuted),
          ),
          actions: [
            AdaptiveButton(
              key: const ValueKey('settings.models.shop'),
              label: 'Open model shop',
              emphasis: ButtonEmphasis.secondary,
              onPressed: () {
                final router = GoRouter.of(context);
                closeSettings(context);
                router.go(Routes.models);
              },
            ),
          ],
        ),
        const AdaptiveSectionHeader('My models'),
        for (final m in library)
          AdaptiveListTile(
            leading: ModelAvatar(m.provider, size: 26),
            title: Text(m.name),
            subtitle: Text(m.id.value),
            trailing: AdaptiveIconButton(
              icon: EveryIcon.close,
              tooltip: 'Remove from My models',
              size: 14,
              onPressed: () => ref.read(libraryProvider.notifier).toggle(m),
            ),
          ),
        if (library.isEmpty)
          AdaptiveListTile(title: Text('No models yet', style: theme.type.body.tint(theme.textMuted))),
      ],
    );
  }
}

/// This computer → Developer: switches for development builds.
class DeveloperSection extends ConsumerWidget {
  const DeveloperSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final config = ref.watch(appConfigProvider);
    return ListView(
      padding: _listPadding,
      children: [
        if (!config.devSkipAuth)
          AdaptiveListTile(
            title: const Text('Nothing to set here'),
            subtitle: Text(
              'Developer switches show in development builds (DEV_SKIP_AUTH).',
              style: theme.type.body.tint(theme.textMuted),
            ),
          )
        else
          switch (ref.watch(devUpstreamProvider)) {
            AsyncData(:final value) => AdaptiveListTile(
              title: const Text('Claude models bill to'),
              subtitle: Text(
                value.hasAnthropicKey
                    ? 'Search and Research always use OpenRouter.'
                    : 'Set ANTHROPIC_API_KEY on the server to use your Anthropic key.',
              ),
              trailing: value.hasAnthropicKey
                  ? settingsPicker(value.claude.label, [
                      for (final u in ClaudeUpstream.values) (u.label, u),
                    ], ref.read(devUpstreamProvider.notifier).set)
                  : Text(value.claude.label, style: theme.type.body.tint(theme.textMuted)),
            ),
            AsyncError() => const AdaptiveListTile(
              title: Text('Claude models bill to'),
              subtitle: Text("Couldn't reach the server's dev settings."),
            ),
            _ => const AdaptiveListTile(title: Text('Claude models bill to')),
          },
      ],
    );
  }
}

/// About: version, server, and the third-party notices (a page of their own).
class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({super.key});

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  bool _notices = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final config = ref.watch(appConfigProvider);
    if (_notices) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: AdaptiveButton(
              label: 'About',
              emphasis: ButtonEmphasis.plain,
              icon: const AdaptiveIcon(EveryIcon.chevronLeft, size: 13),
              onPressed: () => setState(() => _notices = false),
            ),
          ),
          const Expanded(child: NoticesBody()),
        ],
      );
    }
    return ListView(
      padding: _listPadding,
      children: [
        AdaptiveListTile(title: const Text('Version'), subtitle: const Text('0.1.0')),
        AdaptiveListTile(title: const Text('Server'), subtitle: Text(config.apiBaseUrl.toString())),
        AdaptiveListTile(
          title: const Text('Platform'),
          subtitle: Text('${Host.isDesktop ? 'Desktop' : 'Mobile or web'} · ${theme.design.label} design'),
        ),
        SettingsAnchor(
          section: SettingsSection.about,
          id: 'notices',
          child: AdaptiveListTile(
            key: const ValueKey('settings.notices'),
            title: const Text('Third-party notices'),
            subtitle: const Text('Open-source software EveryAI includes, and its licenses'),
            trailing: AdaptiveIcon(EveryIcon.chevronRight, size: 13, color: theme.textMuted),
            onTap: () => setState(() => _notices = true),
          ),
        ),
      ],
    );
  }
}
