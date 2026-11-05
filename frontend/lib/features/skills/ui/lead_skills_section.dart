import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../code/code_providers.dart' show codeProjectsProvider;
import '../../code/drivers/lead_skills.dart';

/// The skills Claude Code lists (its own and the user's, as it reported them when it last started), with a switch
/// each for one project. A skill that is off is passed to the CLI for that project's sessions; nothing is written
/// to `~/.claude`.
class LeadSkillsSection extends ConsumerStatefulWidget {
  const LeadSkillsSection({super.key, this.projectId, this.lead = 'claude-code', this.label = 'Claude Code'});

  /// The project shown first; the picker can change it.
  final String? projectId;
  final String lead;
  final String label;

  @override
  ConsumerState<LeadSkillsSection> createState() => _LeadSkillsSectionState();
}

class _LeadSkillsSectionState extends ConsumerState<LeadSkillsSection> {
  late String? _projectId = widget.projectId;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    ref.watch(leadSkillsProvider);
    final skills = ref.read(leadSkillsProvider.notifier);
    final projects = ref.watch(codeProjectsProvider);
    final project = projects.where((p) => p.id == _projectId).firstOrNull ?? projects.firstOrNull;
    final off = project == null ? const <String>{} : skills.off(project.id, widget.lead);
    // A skill that is off may be left out of the CLI's own list: keep its switch so it can be turned back on.
    final names = {...skills.seen(widget.lead), ...off}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveSectionHeader('${widget.label} skills'),
        if (project == null)
          AdaptiveListTile(
            title: Text('Open a project first', style: TextStyle(color: theme.textMuted)),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AdaptiveMenuButton(
                tooltip: 'Choose the project',
                actions: [
                  for (final p in projects)
                    MenuAction(
                      label: p.name,
                      checked: p.id == project.id,
                      onSelected: () => setState(() => _projectId = p.id),
                    ),
                ],
                child: MenuTrigger(project.name),
              ),
            ),
          ),
          if (names.isEmpty)
            AdaptiveListTile(
              title: Text(
                'None listed yet. They appear after ${widget.label} has run a session on this computer.',
                style: TextStyle(color: theme.textMuted),
              ),
            ),
          for (final n in names)
            AdaptiveListTile(
              title: Text(n),
              trailing: AdaptiveSwitch(
                value: !off.contains(n),
                onChanged: (on) => skills.setOff(project.id, widget.lead, n, off: !on),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'A skill turned off is switched off for ${widget.label} sessions in this project, from their next '
              'start. Skills that come with a ${widget.label} plugin may stay on: the CLI does not always honour the switch.',
              style: theme.type.caption.tint(theme.textMuted),
            ),
          ),
        ],
      ],
    );
  }
}
