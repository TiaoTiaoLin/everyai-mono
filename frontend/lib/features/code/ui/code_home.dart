import '../../../core/preferences.dart';
import '../../../core/ui/brand.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../attachments/attachment.dart';
import '../../../core/platform/platform_kind.dart';
import '../agent_models.dart';
import '../code_providers.dart';
import '../sample/sample_project.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../../slash/slash_command.dart' show CodeSlashHost;
import '../morning_providers.dart';
import 'agent_menu.dart';
import 'code_composer.dart';
import 'transcript/aside_card.dart';
import 'session_view.dart';
import 'code_top_bar.dart' show CodeDraftBar;
import '../code_settings_providers.dart';

/// Where demo sessions "run" (the mock harness ignores the folder).
const demoProjectPath = '${demoScheme}counter-app';

/// Code landing: pick a project, describe the task, start a session.
class CodeHome extends ConsumerStatefulWidget {
  const CodeHome({super.key});

  @override
  ConsumerState<CodeHome> createState() => _CodeHomeState();
}

class _CodeHomeState extends ConsumerState<CodeHome> {
  String? _projectId;
  AgentMode? _picked;
  bool _isolated = false;

  /// A spending cap for the new session (dollars), or null for none.
  double? _budget;
  bool _starting = false;

  /// The mode last used in [projectId]; Auto-edit the first time.
  AgentMode _modeFor(String? projectId) {
    if (_picked case final m?) return m;
    final saved = projectId == null ? null : ref.read(preferencesProvider)[lastModeKey(projectId)];
    return AgentMode.values.asNameMap()[saved] ?? AgentMode.autoEdit;
  }

  void _pickMode(AgentMode mode, String? projectId) {
    setState(() => _picked = mode);
    if (projectId != null) ref.read(preferencesProvider)[lastModeKey(projectId)] = mode.name;
  }

  Future<CodeProject?> _openFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Open');
    if (path == null) return null;
    final project = ref.read(codeProjectsProvider.notifier).add(path);
    setState(() => _projectId = project.id);
    return project;
  }

  Future<void> _addSample() async {
    try {
      final path = await createSampleProject();
      final project = ref.read(codeProjectsProvider.notifier).add(path, name: 'counter-app (sample)');
      setState(() => _projectId = project.id);
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, 'Couldn\'t create the sample project: $e');
    }
  }

  /// A project on a paired host (remote mode).
  void _addDemo() {
    final project = ref.read(codeProjectsProvider.notifier).add(demoProjectPath, name: 'counter-app (demo)');
    setState(() => _projectId = project.id);
  }

  /// The tier the new session runs on: the bar's pick, capped at Thorough
  /// for the scripted demo (it has no phase flow).
  HarnessTier _tierFor(CodeProject project) {
    final tier = ref.read(codeSettingsProvider).tier;
    return tier.phased && isDemoPath(project.path) ? HarnessTier.thorough : tier;
  }

  /// Bug fix isn't in the scripted demo.
  HarnessMode _harnessModeFor(CodeProject project) =>
      isDemoPath(project.path) ? HarnessMode.build : ref.read(codeSettingsProvider).harnessMode;

  /// The lead the new session runs on: the pick, except that the scripted demo always runs its own.
  String _leadFor(CodeProject project) =>
      isDemoPath(project.path) ? everyaiHarnessName : ref.read(codeLeadProvider).harness;

  /// The model and effort for [harness]: an outside lead's own pick, else the EveryAI harness's.
  ({String model, String effort}) _modelFor(String harness) => harness == everyaiHarnessName
      ? (model: ref.read(codeAgentProvider).model, effort: ref.read(codeAgentProvider).effort)
      : ref.read(codeLeadProvider).of(harness);

  Future<void> _start(CodeProject project, String prompt, List<Attachment> files) async {
    final mode = _modeFor(project.id);
    ref.read(preferencesProvider)[lastModeKey(project.id)] = mode.name;
    final harness = _leadFor(project);
    final (:model, :effort) = _modelFor(harness);
    setState(() => _starting = true);
    try {
      final info = await ref
          .read(codeSessionsProvider.notifier)
          .start(
            project: project,
            prompt: prompt,
            model: model,
            effort: effort,
            mode: mode,
            files: files,
            isolated: _isolated,
            tier: _tierFor(project),
            harnessMode: _harnessModeFor(project),
            harness: harness,
          );
      if (_budget case final usd?) ref.read(codeSettingsProvider.notifier).setBudget(info.id, usd);
      if (mounted) context.go(Routes.codeSession(info.id));
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, 'Couldn\'t start the session: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final project = projects.where((p) => p.id == _projectId).firstOrNull ?? projects.firstOrNull;
    final mode = _modeFor(project?.id);
    final lead = project == null || isDemoPath(project.path) ? everyaiHarnessName : ref.watch(codeLeadProvider).harness;
    final sessions = ref
        .watch(codeSessionsProvider)
        .where((s) => s.projectId == project?.id && !s.isSubagent)
        .take(8)
        .toList();

    return AdaptivePage(
      title: '',
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const BrandGlyph('code', active: true, size: 26),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        project == null ? 'Code with an agent' : 'What should we build?',
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: theme.type.largeTitle.regular.copyWith(color: theme.text, letterSpacing: -0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (project == null)
                  _NoProjects(onOpen: _openFolder, onSample: _addSample, onDemo: _addDemo)
                else ...[
                  if (ref.watch(morningBriefProvider) case final brief?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AsideCard(
                        key: ValueKey(brief.id),
                        aside: brief,
                        onDismiss: ref.read(morningBriefProvider.notifier).dismiss,
                      ),
                    ),
                  CodeComposer(
                    project: project.path,
                    slashHost: CodeSlashHost(
                      setMode: (name) => _pickMode(AgentMode.values.byName(name), project.id),
                      morning: ref.read(morningBriefProvider.notifier).refresh,
                    ),
                    busy: _starting,
                    mode: mode,
                    minLines: 3,
                    placeholder: 'Describe a change, a bug to fix, or a feature to build',
                    onModeChanged: (m) => _pickMode(m, project.id),
                    onSend: (text, files) => _start(project, text, files),
                    trailing: AgentMenu(
                      harness: lead,
                      onHarness: isDemoPath(project.path) ? null : ref.read(codeLeadProvider.notifier).chooseHarness,
                      model: lead == everyaiHarnessName
                          ? ref.watch(codeAgentProvider).model
                          : ref.watch(codeLeadProvider).of(lead).model,
                      effort: lead == everyaiHarnessName
                          ? ref.watch(codeAgentProvider).effort
                          : ref.watch(codeLeadProvider).of(lead).effort,
                      demo: isDemoPath(project.path),
                      onChanged: lead == everyaiHarnessName
                          ? ref.read(codeAgentProvider.notifier).chooseModel
                          : (model, effort) => ref.read(codeLeadProvider.notifier).chooseModel(lead, model, effort),
                      tier: ref.watch(codeSettingsProvider.select((s) => s.tier)),
                      onTier: ref.read(codeSettingsProvider.notifier).setTier,
                      harnessMode: ref.watch(codeSettingsProvider.select((s) => s.harnessMode)),
                      onHarnessMode: ref.read(codeSettingsProvider.notifier).setHarnessMode,
                      budget: _budget,
                      onBudget: (v) => setState(() => _budget = v),
                    ),
                    leading: _ProjectPicker(
                      project: project,
                      projects: projects,
                      onPick: (p) => setState(() {
                        _projectId = p.id;
                        _picked = null;
                      }),
                      onOpen: _openFolder,
                      onSample: _addSample,
                      onDemo: _addDemo,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (!isDemoPath(project.path))
                    _SessionOptions(
                      isolated: _isolated,
                      onIsolated: (v) => setState(() => _isolated = v),
                      projectId: project.id,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    _starting && !isDemoPath(project.path)
                        ? 'Starting the agent…'
                        : isDemoPath(project.path)
                        ? 'A demo project with a scripted agent. ${mode.description}.'
                        : _isolated
                        ? 'Works on its own branch in a separate worktree; merge or open a PR when it\'s done. '
                              '${mode.description}.'
                        : 'Works in the project folder, in your shell. Changes shows what it did. ${mode.description}.',
                    textAlign: TextAlign.center,
                    style: theme.type.callout.tint(theme.textMuted),
                  ),
                  if (sessions.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    Text('Recent sessions', style: theme.type.caption.semibold.tint(theme.textMuted)),
                    const SizedBox(height: 6),
                    for (final s in sessions) SessionTile(info: s, onOpen: () => context.go(Routes.codeSession(s.id))),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The prefs key for the mode last used in a project.
String lastModeKey(String projectId) => 'code.lastMode.$projectId';

/// Below the composer: where the session works, and the project's settings.
class _SessionOptions extends StatelessWidget {
  const _SessionOptions({required this.isolated, required this.onIsolated, required this.projectId});

  final bool isolated;
  final ValueChanged<bool> onIsolated;
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget option(String label, bool on, VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: on ? theme.accent.withValues(alpha: 0.12) : null,
            border: Border.all(color: on ? theme.accent : theme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label, style: theme.type.callout.tint(on ? theme.accent : theme.textMuted)),
        ),
      ),
    );
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        option('In place', !isolated, () => onIsolated(false)),
        option('Isolated worktree', isolated, () => onIsolated(true)),
        // The settings popover for the session about to start.
        CodeDraftBar(projectId: projectId),
      ],
    );
  }
}

class _NoProjects extends StatelessWidget {
  const _NoProjects({required this.onOpen, required this.onSample, required this.onDemo});
  final VoidCallback onOpen;
  final VoidCallback onSample;
  final VoidCallback onDemo;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      children: [
        Text(
          'Open a project folder and describe what you want. The agent reads the code, runs commands and edits '
          'files, asking before anything risky.',
          textAlign: TextAlign.center,
          style: theme.type.body.copyWith(color: theme.textMuted, height: 1.45),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            AdaptiveButton(label: 'Open folder…', onPressed: onOpen),
            AdaptiveButton(label: 'Sample project', emphasis: ButtonEmphasis.secondary, onPressed: onSample),
            AdaptiveButton(label: 'Scripted demo', emphasis: ButtonEmphasis.plain, onPressed: onDemo),
          ],
        ),
      ],
    );
  }
}

class _ProjectPicker extends StatelessWidget {
  const _ProjectPicker({
    required this.project,
    required this.projects,
    required this.onPick,
    required this.onOpen,
    required this.onSample,
    required this.onDemo,
  });

  final CodeProject project;
  final List<CodeProject> projects;
  final ValueChanged<CodeProject> onPick;
  final VoidCallback onOpen;
  final VoidCallback onSample;
  final VoidCallback onDemo;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AnchoredPopover(
      width: 300,
      // Many projects with long paths outgrow the popover's height cap.
      builder: (context, close) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PopoverHeader('Projects'),
            // Live, so removing one updates the open list.
            Consumer(
              builder: (context, ref, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in ref.watch(codeProjectsProvider))
                    PopoverRow(
                      key: ValueKey('project.${p.id}'),
                      title: p.name,
                      trailing: AdaptiveIconButton(
                        icon: EveryIcon.close,
                        tooltip: 'Remove from the list (the folder stays)',
                        size: 12,
                        onPressed: () => ref.read(codeProjectsProvider.notifier).remove(p.id),
                      ),
                      subtitle: isDemoPath(p.path) ? 'Scripted demo' : p.path,
                      selected: p.id == project.id,
                      onTap: () {
                        close();
                        onPick(p);
                      },
                    ),
                ],
              ),
            ),
            if (Host.isDesktop) ...[
              PopoverRow(
                leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
                title: 'Open folder…',
                onTap: () {
                  close();
                  onOpen();
                },
              ),
              PopoverRow(
                leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
                title: 'New sample project',
                subtitle: 'A small Dart repo for the real agent',
                onTap: () {
                  close();
                  onSample();
                },
              ),
            ],
            if (!projects.any((p) => isDemoPath(p.path)))
              PopoverRow(
                leading: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.textMuted),
                title: 'Scripted demo',
                onTap: () {
                  close();
                  onDemo();
                },
              ),
          ],
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveIcon(EveryIcon.projects, size: 13, color: theme.textMuted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                project.name,
                overflow: TextOverflow.ellipsis,
                style: theme.type.callout.medium.tint(theme.textMuted),
              ),
            ),
            const SizedBox(width: 4),
            AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: theme.textMuted),
          ],
        ),
      ),
    );
  }
}

/// A session in a list: status dot, title, age.
class SessionTile extends ConsumerStatefulWidget {
  const SessionTile({super.key, required this.info, required this.onOpen, this.selected = false, this.dense = false});

  final CodeSessionInfo info;
  final VoidCallback onOpen;
  final bool selected;
  final bool dense;

  @override
  ConsumerState<SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends ConsumerState<SessionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    // Open sessions have a live status; the rest come from the harness.
    final status = ref.exists(codeSessionProvider(widget.info.id))
        ? ref.watch(codeSessionProvider(widget.info.id).select((s) => s.status))
        : ref.watch(codeStatusesProvider.select((all) => all[widget.info.id])) ?? SessionStatus.idle;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: Semantics(
          button: true,
          selected: widget.selected,
          label: '${widget.info.title}, ${status.label}',
          child: Container(
            margin: EdgeInsets.symmetric(horizontal: widget.dense ? 8 : 0, vertical: 1),
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: widget.dense ? 7 : 9),
            decoration: BoxDecoration(
              color: widget.selected
                  ? theme.text.withValues(alpha: 0.09)
                  : _hover
                  ? theme.text.withValues(alpha: 0.05)
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                StatusPill(status: status, dense: true),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.info.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.callout.tint(theme.text),
                  ),
                ),
                if (!widget.dense) Text(_age(widget.info.createdAt), style: theme.type.caption.tint(theme.textMuted)),
                Opacity(
                  opacity: _hover || widget.selected || Host.isMobile ? 1 : 0,
                  child: AdaptiveMenuButton(
                    tooltip: 'Session options',
                    actions: [
                      MenuAction(label: 'Rename', icon: EveryIcon.edit, onSelected: _rename),
                      MenuAction(label: 'Export transcript…', icon: EveryIcon.download, onSelected: _export),
                      MenuAction(label: 'Delete', icon: EveryIcon.delete, destructive: true, onSelected: _delete),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: AdaptiveIcon(EveryIcon.more, size: 14, color: theme.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Saves the session as Markdown (to compare runs, or keep a record).
  Future<void> _export() async {
    final markdown = await ref.read(codeSessionProvider(widget.info.id).notifier).exportMarkdown();
    if (markdown.isEmpty) return;
    final name = '${widget.info.title}-${widget.info.harness}'
        .replaceAll(RegExp(r'[^\w\- ]+'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-');
    final location = await getSaveLocation(suggestedName: '$name.md');
    if (location == null) return;
    try {
      await XFile.fromData(Uint8List.fromList(utf8.encode(markdown)), mimeType: 'text/markdown').saveTo(location.path);
      if (mounted) showAdaptiveToast(context, 'Saved');
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, "Couldn't save: $e");
    }
  }

  Future<void> _rename() async {
    final title = await showAdaptivePrompt(
      context,
      title: 'Rename session',
      initialValue: widget.info.title,
      confirmLabel: 'Rename',
    );
    if (title == null || title.trim().isEmpty) return;
    ref.read(codeSessionsProvider.notifier).update(widget.info.copyWith(title: title.trim()));
  }

  Future<void> _delete() async {
    final w = widget.info.worktree;
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Delete session?',
      message: w == null
          ? '"${widget.info.title}" will be removed from your sessions.'
          : '"${widget.info.title}" will be removed with its worktree, branch ${w.branch} and checkpoints. '
                'Work already merged stays merged.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final selected = widget.selected;
    try {
      if (w == null) {
        await ref.read(codeSessionsProvider.notifier).remove(widget.info.id);
      } else {
        await ref.read(codeGitProvider(widget.info.id).notifier).discard();
      }
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, "Couldn't delete the session: $e");
      return;
    }
    if (selected && mounted) context.go(Routes.code);
  }

  static String _age(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}
