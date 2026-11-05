import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/brand.dart';
import '../../code/code_providers.dart';

/// The folders the Code workspace has opened, with how many sessions each
/// holds. Chat has no projects of its own; this is the index of the Code ones.
class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final sessions = ref.watch(codeSessionsProvider);
    return AdaptivePage(
      title: 'Projects',
      body: projects.isEmpty
          ? BrandEmptyState(
              kind: 'empty-chats',
              title: 'No projects yet',
              message: 'Open a folder in Code and the agent works inside it. Its sessions are listed here.',
              action: AdaptiveButton(label: 'Open Code', onPressed: () => context.go(Routes.code)),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
                  children: [
                    for (final p in projects)
                      AdaptiveListTile(
                        title: Text(p.name),
                        subtitle: Text(
                          '${p.path}\n${_count(sessions.where((s) => s.projectId == p.id).length)}',
                          style: theme.type.body.tint(theme.textMuted),
                        ),
                        onTap: () => context.go(Routes.code),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  static String _count(int n) => n == 0 ? 'No sessions' : '$n session${n == 1 ? '' : 's'}';
}
