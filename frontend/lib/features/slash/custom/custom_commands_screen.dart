import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../code/code_providers.dart';
import 'command_store.dart';
import 'custom_command.dart';
import 'custom_commands_provider.dart';

/// Settings → Custom commands: the Markdown prompts behind `/name`, global and
/// per Code project. Editing opens the file in the user's text editor.
class CustomCommandsBody extends ConsumerWidget {
  const CustomCommandsBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final commands = ref.watch(customCommandsProvider);
    final projects = ref.watch(codeProjectsProvider);
    final ctl = ref.read(customCommandsProvider.notifier);
    final trust = ref.watch(commandTrustProvider);
    final all = commands.value ?? const <CustomCommand>[];

    Future<void> add(CodeProjectRef? project) async {
      final name = await showAdaptivePrompt(
        context,
        title: project == null ? 'New global command' : 'New command in ${project.name}',
        confirmLabel: 'Create',
      );
      if (name == null || name.trim().isEmpty) return;
      try {
        final c = await ctl.create(name.trim().replaceFirst('/', '').toLowerCase(), project: project);
        await _open(c);
      } on StateError catch (e) {
        if (context.mounted) {
          await showAdaptiveConfirm(context, title: 'Could not create', message: e.message, confirmLabel: 'OK');
        }
      }
    }

    Widget section(String title, CodeProjectRef? project, List<CustomCommand> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveSectionHeader(title),
        if (items.isEmpty)
          AdaptiveListTile(title: Text('No commands yet', style: theme.type.body.tint(theme.textMuted))),
        for (final c in items)
          AdaptiveListTile(
            title: Text('/${c.name}${c.args == null ? '' : ' ${c.args}'}'),
            subtitle: trust.lockedNote(c) != null
                ? Text(trust.lockedNote(c)!)
                : c.description.isEmpty
                ? null
                : Text(c.description),
            onTap: () => _open(c),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!trust.trustedNow(c))
                  AdaptiveButton(
                    label: 'Review…',
                    emphasis: ButtonEmphasis.secondary,
                    onPressed: () => ref.read(commandTrustProvider.notifier).review(context, c),
                  )
                else if (!c.isGlobal)
                  AdaptiveIconButton(
                    icon: EveryIcon.close,
                    tooltip: 'Stop trusting',
                    onPressed: () => ref.read(commandTrustProvider.notifier).set(c, false),
                  ),
                AdaptiveIconButton(
                  icon: EveryIcon.edit,
                  tooltip: 'Edit in your text editor',
                  onPressed: () => _open(c),
                ),
                AdaptiveIconButton(
                  icon: EveryIcon.delete,
                  tooltip: 'Delete',
                  onPressed: () async {
                    final ok = await showAdaptiveConfirm(
                      context,
                      title: 'Delete /${c.name}?',
                      message: 'The file ${c.path ?? c.name} is removed.',
                      confirmLabel: 'Delete',
                      destructive: true,
                    );
                    if (ok) await ctl.remove(c);
                  },
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: AdaptiveButton(
              label: 'New command',
              emphasis: ButtonEmphasis.secondary,
              icon: const AdaptiveIcon(EveryIcon.add, size: 14),
              onPressed: () => add(project),
            ),
          ),
        ),
      ],
    );

    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'A command is a Markdown file. Type / in a composer to run it; \$ARGUMENTS in the file is replaced by '
            'what you type after the name. Add description, args, mode and model lines between --- marks at the top.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
        section('Global', null, [
          for (final c in all)
            if (c.isGlobal) c,
        ]),
        for (final p in projects)
          section(
            p.name,
            (name: p.name, path: p.path),
            [
              for (final c in all)
                if (c.project == p.name && c.path?.startsWith(p.path) == true) c,
            ],
          ),
        FutureBuilder<String?>(
          future: globalCommandsDir(),
          builder: (_, s) => s.data == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    'Global folder: ${s.data}\nProject folders: <project>/.everyai/commands',
                    style: theme.type.caption.tint(theme.textMuted),
                  ),
                ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AdaptiveButton(label: 'Reload', emphasis: ButtonEmphasis.secondary, onPressed: ctl.reload),
          ),
        ),
      ],
    );
  }

  static Future<void> _open(CustomCommand c) async {
    final path = c.path;
    if (path != null) await launchUrl(Uri.file(path));
  }
}
