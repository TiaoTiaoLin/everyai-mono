import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/platform/platform_kind.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/delivered_files.dart';
import '../../domain/transcript.dart';
import '../console/console_state.dart';

/// The files the agent presented with `present_files`: one row each, to open,
/// show in the file manager, or look at in the Changes pane.
class FilesCard extends ConsumerWidget {
  const FilesCard({super.key, required this.item, required this.workingDir, this.sessionId});

  final FilesDelivered item;
  final String workingDir;

  /// Enables the Changes shortcut.
  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final files = item.files;
    if (files.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(files.length == 1 ? 'Result' : 'Results', style: theme.type.caption.semibold.tint(theme.textMuted)),
          const SizedBox(height: 4),
          for (final f in files)
            _FileRow(
              file: f,
              path: resolveDelivered(workingDir, f.path),
              onChanges: sessionId == null
                  ? null
                  : () => ref.read(consolePanelProvider(sessionId!).notifier).show(ConsoleView.diff),
            ),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.path, this.onChanges});

  final DeliveredFile file;
  final String path;
  final VoidCallback? onChanges;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    // Elsewhere (a device mirroring the computer's session) the file is on the computer.
    final local = Host.isDesktop;
    final exists = local && (File(path).existsSync() || Directory(path).existsSync());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          AdaptiveIcon(EveryIcon.document, size: 16, color: exists || !local ? theme.accent : theme.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.body.medium.tint(theme.text),
                ),
                Text(
                  exists || !local
                      ? (file.description.isNotEmpty ? file.description : file.path)
                      : '${file.path} (not found)',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.copyWith(color: theme.textMuted, height: 1.35),
                ),
              ],
            ),
          ),
          if (exists) ...[
            AdaptiveIconButton(
              icon: EveryIcon.external,
              tooltip: 'Open',
              size: 15,
              onPressed: () => launchUrl(Uri.file(path)),
            ),
            AdaptiveIconButton(
              icon: EveryIcon.projects,
              tooltip: 'Show in file manager',
              size: 15,
              onPressed: () => revealDelivered(path),
            ),
            if (onChanges != null)
              AdaptiveIconButton(icon: EveryIcon.code, tooltip: 'Show in Changes', size: 15, onPressed: onChanges),
          ],
        ],
      ),
    );
  }
}
