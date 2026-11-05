// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../code/code_providers.dart' show codeStatusesProvider;
import '../../code/domain/code_session.dart' show SessionStatus;
import '../data/install.dart';
import '../update_providers.dart';

/// The sidebar's update notice, above the account row: "EveryAI 0.1.0-alpha.2 is ready · What's new · Restart to
/// update · Later", or a download for an install that can't update itself. Nothing when there's nothing to do.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key, this.collapsed = false});

  /// The rail: just an icon that restarts (or downloads).
  final bool collapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateProvider);
    final release = update.release;
    if (!update.showBanner || release == null) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    final ready = update.phase == UpdatePhase.ready;
    final title = ready ? 'EveryAI ${release.version} is ready' : 'EveryAI ${release.version} is out';
    final act = ready ? () => restartForUpdate(context, ref) : () => _open(ref.read(updateProvider.notifier).manualUrl);
    final label = ready
        ? 'Restart to update'
        : update.kind == InstallKind.deb
        ? 'Download .deb'
        : 'Download';
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: AdaptiveIconButton(
            icon: EveryIcon.download,
            color: theme.accent,
            tooltip: '$title. $label',
            onPressed: act,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: theme.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.accent.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AdaptiveIcon(EveryIcon.download, size: 14, color: theme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.callout.semibold.tint(theme.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AdaptiveButton(label: label, onPressed: act),
                if (release.pageUrl.isNotEmpty)
                  AdaptiveButton(
                    label: "What's new",
                    emphasis: ButtonEmphasis.plain,
                    onPressed: () => _open(release.pageUrl),
                  ),
                AdaptiveButton(
                  label: 'Later',
                  emphasis: ButtonEmphasis.plain,
                  onPressed: ref.read(updateProvider.notifier).later,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Restarts into the downloaded update, asking first when Code sessions are still working (a restart stops them).
Future<void> restartForUpdate(BuildContext context, WidgetRef ref) async {
  final working = ref
      .read(codeStatusesProvider)
      .values
      .where((s) => s == SessionStatus.running || s == SessionStatus.starting)
      .length;
  if (working > 0) {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Restart to update?',
      message: working == 1
          ? 'A Code session is still working. Restarting stops it; you can carry on after the update.'
          : '$working Code sessions are still working. Restarting stops them; you can carry on after the update.',
      confirmLabel: 'Restart',
    );
    if (!ok) return;
  }
  await ref.read(updateProvider.notifier).restart();
}

Future<void> _open(String? url) async {
  if (url == null || url.isEmpty) return;
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Settings → About: the update status, Check now, and the pre-release switch.
class UpdateSettingsTiles extends ConsumerWidget {
  const UpdateSettingsTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateProvider);
    final controller = ref.read(updateProvider.notifier);
    final theme = EveryTheme.of(context);
    final release = update.release;
    final (status, Widget? action) = switch (update.phase) {
      _ when !update.supported && update.phase != UpdatePhase.checking => (_unsupported, null),
      UpdatePhase.idle || UpdatePhase.upToDate => (
        update.checkedAt == null ? 'Not checked yet' : "You're on the latest version",
        AdaptiveButton(label: 'Check now', emphasis: ButtonEmphasis.secondary, onPressed: controller.check),
      ),
      UpdatePhase.checking => (
        'Checking for updates…',
        const SizedBox.square(dimension: 16, child: AdaptiveProgress()),
      ),
      UpdatePhase.downloading => (
        'Downloading ${release?.version ?? 'the update'}'
            '${update.progress == null ? '…' : ' · ${(update.progress! * 100).round()}%'}',
        const SizedBox.square(dimension: 16, child: AdaptiveProgress()),
      ),
      UpdatePhase.ready => (
        '${release?.version} is downloaded',
        AdaptiveButton(label: 'Restart to update', onPressed: () => restartForUpdate(context, ref)),
      ),
      UpdatePhase.manual => (
        '${release?.version} is out',
        AdaptiveButton(
          label: update.kind == InstallKind.deb ? 'Download .deb' : 'Download',
          onPressed: () => _open(controller.manualUrl),
        ),
      ),
      UpdatePhase.failed => (
        update.error ?? 'The update failed',
        AdaptiveButton(label: 'Try again', emphasis: ButtonEmphasis.secondary, onPressed: controller.check),
      ),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveListTile(
          key: const ValueKey('settings.updates'),
          title: const Text('Updates'),
          subtitle: Text(status, style: update.phase == UpdatePhase.failed ? TextStyle(color: theme.danger) : null),
          trailing: action,
        ),
        if (update.supported)
          AdaptiveListTile(
            title: const Text('Get pre-releases'),
            subtitle: const Text('Alpha and beta builds that GitHub doesn\'t mark as the latest release'),
            trailing: AdaptiveSwitch(value: controller.prereleases, onChanged: controller.setPrereleases),
          ),
      ],
    );
  }

  static const _unsupported =
      'This copy updates through the Microsoft Store, the App Store or your package manager; development builds '
      "don't update.";
}
