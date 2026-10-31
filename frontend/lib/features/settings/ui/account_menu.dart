import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../auth/auth_providers.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/profile.dart';
import '../settings_registry.dart';
import 'settings_modal.dart';

/// The name and plan the account row shows: from [profile] (`/v1/me`) when
/// it has loaded, else placeholders by sign-in state.
(String name, String plan) accountSummary(AuthState auth, [Profile? profile]) => switch (auth) {
  Bypassed() when profile != null => (profile.displayName, '${profile.planLabel} · Developer mode'),
  Bypassed() => ('Guest', 'Developer mode'),
  SignedIn() when profile != null => (profile.displayName, profile.planLabel),
  SignedIn() => ('Account', 'Signed in'),
  _ => ('Signed out', ''),
};

/// Asks, then signs out. Chats stay on this device.
Future<void> confirmSignOut(BuildContext context, WidgetRef ref) async {
  final ok = await showAdaptiveConfirm(
    context,
    title: 'Log out?',
    message: 'Chats stay on this device.',
    confirmLabel: 'Log out',
    destructive: true,
  );
  if (ok) await ref.read(authProvider.notifier).signOut();
}

/// The user's initial in a tinted circle.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, required this.name, this.size = 30});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: theme.accent.withValues(alpha: 0.25), shape: BoxShape.circle),
      child: Center(
        child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: theme.type.callout.semibold.tint(theme.text)),
      ),
    );
  }
}

/// The sidebar's account row: avatar, name and plan, and a devices button
/// (Remote). Tapping it opens the account menu above it. [collapsed]: the
/// rail shows the avatar alone.
class AccountRow extends ConsumerWidget {
  const AccountRow({super.key, required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final (name, plan) = accountSummary(ref.watch(authProvider), ref.watch(profileProvider).value);
    final avatar = AccountAvatar(name: name);
    final trigger = Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
      child: collapsed
          ? Center(child: avatar)
          : Row(
              children: [
                avatar,
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.body.semibold.tint(theme.text),
                      ),
                      if (plan.isNotEmpty)
                        Text(
                          plan,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption.tint(theme.textMuted),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: theme.textMuted),
              ],
            ),
    );
    final menu = Semantics(
      button: true,
      label: 'Account menu',
      child: AnchoredPopover(
        key: const ValueKey('account.menu'),
        width: 260,
        maxHeight: 560,
        builder: (context, close) => AccountMenu(close: close),
        child: trigger,
      ),
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: collapsed
            ? menu
            : Row(
                children: [
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: menu),
                  ),
                  AdaptiveIconButton(
                    key: const ValueKey('account.devices'),
                    icon: EveryIcon.devices,
                    tooltip: 'Remote devices',
                    size: 16,
                    onPressed: () => showSettings(context, section: SettingsSection.remote),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The account popover's items. Get help, Get apps and Learn more have
/// nowhere to go yet: they are shown, and do nothing.
class AccountMenu extends ConsumerWidget {
  const AccountMenu({super.key, required this.close});

  final VoidCallback close;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    void open(SettingsSection section, {String? anchor}) {
      close();
      showSettings(context, section: section, anchor: anchor);
    }

    Widget icon(EveryIcon i) => AdaptiveIcon(i, size: 16, color: theme.textMuted);
    Widget hint(String s) => Text(s, style: theme.type.caption.tint(theme.textMuted));
    Widget divider() => Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: theme.border);
    final cmd = Host.isApple ? '⌘,' : 'Ctrl+,';
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PopoverRow(
            key: const ValueKey('account.settings'),
            title: 'Settings',
            leading: icon(EveryIcon.settings),
            trailing: hint(cmd),
            onTap: () => open(SettingsSection.general),
          ),
          PopoverRow(
            key: const ValueKey('account.usage'),
            title: 'Usage',
            leading: icon(EveryIcon.usage),
            onTap: () => open(SettingsSection.usage),
          ),
          PopoverRow(
            key: const ValueKey('account.language'),
            title: 'Language',
            leading: icon(EveryIcon.language),
            onTap: () => open(SettingsSection.general, anchor: 'language'),
          ),
          // Not wired yet: shown, no action.
          _DeadRow(key: const ValueKey('account.help'), title: 'Get help', leading: icon(EveryIcon.help)),
          divider(),
          PopoverRow(
            key: const ValueKey('account.plans'),
            title: 'View all plans',
            leading: icon(EveryIcon.card),
            onTap: () => open(SettingsSection.billing, anchor: 'plans'),
          ),
          _DeadRow(
            key: const ValueKey('account.apps'),
            title: 'Get apps and extensions',
            leading: icon(EveryIcon.devices),
          ),
          _DeadRow(
            key: const ValueKey('account.learn'),
            title: 'Learn more',
            leading: icon(EveryIcon.info),
            trailing: AdaptiveIcon(EveryIcon.chevronRight, size: 12, color: theme.textMuted),
          ),
          divider(),
          PopoverRow(
            key: const ValueKey('account.keys'),
            title: 'Add API keys',
            leading: icon(EveryIcon.key),
            onTap: () => open(SettingsSection.apiKeys),
          ),
          divider(),
          PopoverRow(
            key: const ValueKey('account.logout'),
            title: 'Log out',
            leading: icon(EveryIcon.signOut),
            onTap: () {
              close();
              confirmSignOut(context, ref);
            },
          ),
        ],
      ),
    );
  }
}

/// A menu row that looks live but has no action yet.
class _DeadRow extends StatelessWidget {
  const _DeadRow({super.key, required this.title, this.leading, this.trailing});

  final String title;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => PopoverRow(title: title, leading: leading, trailing: trailing, onTap: () {});
}
