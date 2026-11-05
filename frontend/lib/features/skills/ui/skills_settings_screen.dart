import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../code/code_providers.dart' show codeProjectsProvider;
import '../../code/domain/code_session.dart';
import '../data/skill_import.dart';
import '../domain/hidden_instructions.dart';
import '../data/skill_store.dart';
import '../skills_providers.dart';
import 'lead_skills_section.dart';

/// Settings → Skills: the Agent Skills Code sessions (and, without project
/// skills or script skills, Chat) can use. Skills in the
/// EveryAI library and `~/.agents/skills` are on unless turned off; skills
/// that came with a project stay off until the user reviews and trusts them.
class SkillsSettingsBody extends ConsumerWidget {
  const SkillsSettingsBody({super.key, this.projectId});

  /// The project whose Claude Code skills are listed first (from the Code settings link).
  final String? projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final skills = ref.watch(installedSkillsProvider);
    final settings = ref.watch(skillSettingsProvider);
    final projects = ref.watch(codeProjectsProvider);
    final all = skills.value ?? const <InstalledSkill>[];
    final globalWinners = winnersFor(all, null);

    Widget section(String title, List<InstalledSkill> items, {String? empty, Map<String, InstalledSkill>? winners}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AdaptiveSectionHeader(title),
            if (items.isEmpty && empty != null)
              AdaptiveListTile(title: Text(empty, style: theme.type.body.tint(theme.textMuted))),
            for (final s in items)
              _SkillTile(
                skill: s,
                settings: settings,
                shadowedBy: switch ((winners ?? globalWinners)[s.name]) {
                  final w? when w.usable && s.usable && w.key != s.key => w,
                  _ => null,
                },
              ),
          ],
        );

    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        Text(
          'A skill is a folder with a SKILL.md: instructions, and sometimes scripts and reference files, that the '
          'Code agent loads when a task calls for it. Chat can use the EveryAI and ~/.agents/skills ones too, '
          'except skills that run programs. Only the name and description sit in the prompt until a skill is used.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _importMenu(context, ref, 'Import folder…', projects, zip: false),
              _importMenu(context, ref, 'Import zip…', projects, zip: true),
              AdaptiveButton(
                label: 'Reload',
                emphasis: ButtonEmphasis.secondary,
                onPressed: ref.read(installedSkillsProvider.notifier).reload,
              ),
            ],
          ),
        ),
        if (skills case AsyncError(:final error))
          Text("Couldn't read the skills folders: $error", style: theme.type.body.tint(theme.danger)),
        LeadSkillsSection(projectId: projectId),
        section('EveryAI library', [
          ...all.where((s) => s.source == SkillSource.library),
        ], empty: 'Nothing imported yet'),
        section('Shared (~/.agents/skills)', [
          ...all.where((s) => s.source == SkillSource.shared),
        ], empty: 'No skills in ~/.agents/skills'),
        for (final p in projects)
          if (all.any((s) => s.projectId == p.id))
            section(p.name, [...all.where((s) => s.projectId == p.id)], winners: winnersFor(all, p.id)),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            'Project skills live in <project>/.agents/skills. A skill that came with a repository stays off until '
            'you review it, and goes off again if its files change. Lines like !`command` are shown to the agent '
            'as text; they never run on their own.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }

  static Widget _importMenu(
    BuildContext context,
    WidgetRef ref,
    String label,
    List<CodeProject> projects, {
    required bool zip,
  }) {
    return AdaptiveMenuButton(
      tooltip: 'Choose where the skill goes',
      actions: [
        MenuAction(
          label: 'Into the EveryAI library',
          onSelected: () => _import(context, ref, zip: zip),
        ),
        for (final p in projects)
          MenuAction(
            label: 'Into ${p.name}',
            onSelected: () => _import(context, ref, zip: zip, project: p),
          ),
      ],
      child: MenuTrigger(label),
    );
  }

  static Future<void> _import(BuildContext context, WidgetRef ref, {required bool zip, CodeProject? project}) async {
    final List<SkillFile> files;
    final String fallback;
    try {
      if (zip) {
        final file = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Zip', extensions: ['zip', 'skill'], uniformTypeIdentifiers: ['public.zip-archive']),
          ],
        );
        if (file == null) return;
        if (await file.length() > 64 * 1024 * 1024) throw StateError('The zip is larger than 64 MB.');
        files = zipSkillFiles(await file.readAsBytes());
        fallback = file.name.replaceFirst(RegExp(r'\.(zip|skill)$'), '');
      } else {
        final path = await getDirectoryPath(confirmButtonText: 'Import');
        if (path == null) return;
        files = await folderFiles(path);
        fallback = path.split('/').where((s) => s.isNotEmpty).last;
      }
    } on Object catch (e) {
      if (context.mounted) await _tell(context, 'Could not read it', '$e');
      return;
    }
    final candidates = await findImportCandidates(files, fallbackName: fallback);
    if (!context.mounted) return;
    if (candidates.isEmpty) {
      await _tell(context, 'No skills found', 'There is no SKILL.md in it.');
      return;
    }
    final lines = await importSkillCandidates(context, ref, candidates, project: project);
    if (lines == null) return;
    if (!context.mounted) return;
    await _tell(context, candidates.length == 1 ? 'Import' : 'Imported skills', lines.join('\n\n'));
  }

  static Future<void> _tell(BuildContext context, String title, String message) =>
      showAdaptiveConfirm(context, title: title, message: message, confirmLabel: 'OK');
}

/// Installs the [candidates] that passed their check, into [project] when given, and returns a summary line for each.
/// A candidate with hidden or suspicious text is installed only when the user says so (a project import is trusted at
/// once). Null when the screen went away meanwhile.
Future<List<String>?> importSkillCandidates(
  BuildContext context,
  WidgetRef ref,
  List<ImportCandidate> candidates, {
  CodeProject? project,
}) async {
  final lines = <String>[];
  for (final c in candidates) {
    if (!c.ok) {
      lines.add('${c.dirName}: not imported.\n${c.check.report.errors.map((e) => '• $e').join('\n')}');
      continue;
    }
    // Hidden or suspicious text: the user decides before anything is installed (a project import is trusted).
    if (c.findings.isNotEmpty) {
      if (!context.mounted) return null;
      final go = await showAdaptiveConfirm(
        context,
        title: 'Import ${c.dirName}?',
        message: '${findingsMessage(c.findings)}\n\nCancel skips this skill.',
        confirmLabel: 'Import anyway',
      );
      if (!context.mounted) return null;
      if (!go) {
        lines.add('${c.dirName}: skipped.');
        continue;
      }
    }
    try {
      await ref.read(installedSkillsProvider.notifier).import(c, projectId: project?.id, projectPath: project?.path);
      final warnings = c.check.report.warnings;
      lines.add(
        '${c.dirName}: imported${c.check.report.hasScripts ? ' (has scripts)' : ''}.'
        '${warnings.isEmpty ? '' : '\n${warnings.map((w) => '• $w').join('\n')}'}',
      );
    } on StateError catch (e) {
      lines.add('${c.dirName}: ${e.message}');
    } on Object catch (e) {
      lines.add('${c.dirName}: $e');
    }
  }
  return lines;
}

class _SkillTile extends ConsumerWidget {
  const _SkillTile({required this.skill, required this.settings, this.shadowedBy});

  final InstalledSkill skill;
  final SkillSettings settings;
  final InstalledSkill? shadowedBy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final s = skill;
    final ctl = ref.read(skillSettingsProvider.notifier);
    final status = skillStatus(s, settings, shadowedBy: shadowedBy);
    final needsTrust = s.usable && !settings.trustedNow(s);
    final notes = [
      if (s.usable && skillNeedsCode(s))
        s.source == SkillSource.project
            ? 'Runs programs'
            : 'Needs Code: runs programs, so Chat lists it but cannot use it'
      else if (s.report.hasScripts)
        'Has scripts',
      ...s.report.warnings,
      if (status != null && status != 'Off') status,
    ];
    return AdaptiveListTile(
      title: Text(s.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.manifest case final m?) Text(m.description, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (notes.isNotEmpty)
            Text(
              notes.join(' · '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.type.caption.tint(s.usable ? theme.textMuted : theme.danger),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (needsTrust)
            AdaptiveButton(label: 'Review…', emphasis: ButtonEmphasis.secondary, onPressed: () => _review(context, ctl))
          else
            AdaptiveSwitch(
              value: s.usable && settings.enabled(s),
              onChanged: s.usable ? (on) => ctl.setEnabled(s, on) : null,
            ),
          AdaptiveMenuButton(
            tooltip: 'More',
            actions: [
              MenuAction(
                label: 'Open folder',
                icon: EveryIcon.projects,
                onSelected: () => launchUrl(Uri.directory(s.dir)),
              ),
              if (s.source == SkillSource.project && settings.trusted.containsKey(s.key))
                MenuAction(label: 'Stop trusting', onSelected: () => ctl.untrust(s)),
              MenuAction(
                label: 'Remove…',
                icon: EveryIcon.delete,
                destructive: true,
                onSelected: () => _remove(context, ref),
              ),
            ],
            child: const Padding(padding: EdgeInsets.all(6), child: AdaptiveIcon(EveryIcon.more, size: 16)),
          ),
        ],
      ),
    );
  }

  Future<void> _review(BuildContext context, SkillSettingsNotifier ctl) async {
    final m = skill.manifest!;
    // The bundled files are scanned now, not on every scan; trust still binds to the digest of all of them.
    final findings = await scanSkillFolder(skill);
    if (!context.mounted) return;
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Trust ${m.name}?',
      message:
          'This skill came with the project, in ${skill.dir}. The agent will follow its instructions'
          '${skill.report.hasScripts ? ' and may run its scripts (each command still asks in Ask mode)' : ''}.\n\n'
          '${m.description}${findings.isEmpty ? '' : '\n\n${findingsMessage(findings)}'}',
      // The whole body as the agent gets it (hidden characters removed): trust covers all of it.
      detail: m.body,
      confirmLabel: findings.isEmpty ? 'Trust and turn on' : 'Trust anyway',
    );
    if (ok) ctl.trust(skill);
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Remove ${skill.name}?',
      message: 'The folder ${skill.dir} is deleted.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (ok) await ref.read(installedSkillsProvider.notifier).remove(skill);
  }
}
