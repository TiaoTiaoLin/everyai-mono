import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../billing/billing_providers.dart' show formatMicros;
import '../../../models/domain/model_catalog.dart';
import '../../../models/models_providers.dart';
import '../../../remote/remote_providers.dart' show remoteHostingProvider;
import '../../settings/context_files_stub.dart' if (dart.library.io) '../../settings/context_files_io.dart' as io;
import '../../../settings/settings_registry.dart';
import '../../../settings/ui/settings_modal.dart';
import '../../../usage/usage_totals.dart';
import '../../code_providers.dart';
import '../../limit_providers.dart' show codePlanLimitsProvider;
import '../../code_settings_providers.dart' show codeSettingsProvider;
import '../../domain/code_session.dart';
import '../../drivers/driver_policy.dart' show fidelityNote;
import '../../drivers/driver_registry.dart';
import '../../drivers/usage_limit.dart';
import '../../harness/events.dart' show PlanLimits, PlanWindow;
import '../../settings/code_settings.dart' show SettingsScope, budgetFill;
import '../code_top_bar.dart' show harnessUsageLine;
import '../../domain/transcript.dart' show NoticeItem;
import '../transcript/transcript_items.dart' show displayPath;
import 'console_state.dart';
import 'context_breakdown.dart';
import 'git_button.dart';
import 'running_work.dart';

/// How this desktop's remote control stands, in one line for Session info (tests swap it).
final sessionRemoteLineProvider = Provider.autoDispose<String>((ref) {
  final hosting = ref.watch(remoteHostingProvider);
  if (!hosting.enabled) return 'Off';
  return hosting.link.connected ? 'On: your paired devices can follow this session' : 'On, not connected to the relay';
});

/// Session info's Environment, as label and value rows.
List<(String, String)> environmentRows({
  required String harness,
  required String model,
  String? fidelity,
  required String project,
  required CodeSessionInfo info,
  required String remote,
}) {
  final w = info.worktree;
  final b = info.baseline;
  return [
    ('Harness', harness),
    ('Model', model),
    if (fidelity != null) ('Mode', fidelity),
    ('Project', project),
    if (w != null)
      ('Branch', '${w.branch} → ${w.baseBranch} · own worktree')
    else if (b != null)
      ('Branch', 'In place${b.branch.isEmpty ? '' : ' on ${b.branch}'} · your own checkout')
    else if (!noLocalFolder(info.workingDir))
      ('Branch', 'Not a git repository'),
    ('Remote control', remote),
  ];
}

/// "14:05", or "Mon 14:05" when it isn't today.
String _clock(DateTime t, DateTime now) {
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
  return '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1]} $hm';
}

/// A plan window's name for people: Claude Code's `five_hour`, `seven_day`, `seven_day_opus`; others by length.
String planWindowName(PlanWindow w) {
  final model = switch (w.name.split('seven_day_')) {
    [_, final m] when m.isNotEmpty => ' (${m[0].toUpperCase()}${m.substring(1)})',
    _ => '',
  };
  return switch (w.minutes) {
    300 => '5-hour window',
    10080 => 'This week$model',
    final m? when m % 1440 == 0 => '${m ~/ 1440}-day window',
    final m? when m % 60 == 0 => '${m ~/ 60}-hour window',
    _ => w.name,
  };
}

/// Session info's Usage + limits, as lines: what was used and how it was paid, the cap, and the plan: the limit when
/// it was hit ([limit]), else each window the harness last reported ([plan]: "This week: 35% used · resets Mon 19:59").
/// An [outsideLabel] lead that reported neither says so rather than showing a guess.
List<String> usageLines({
  required UsageTotals totals,
  double? budget,
  UsageLimit? limit,
  PlanLimits? plan,
  String? outsideLabel,
  DateTime? now,
}) => [
  totals.isEmpty ? 'No model calls yet' : '${totals.calls} calls · ${harnessUsageLine(totals)}',
  if (budget == null)
    'No spending cap'
  else
    'Cap ${formatMicros((budget * 1e6).round())} · '
        '${((budgetFill(totals.chargedMicros, budget) ?? 0) * 100).round()}% spent',
  if (limit != null)
    'Limit reached${limit.resetsAt == null ? '' : ' · resets ${_clock(limit.resetsAt!.toLocal(), now ?? DateTime.now())}'}'
  else if (plan != null && plan.windows.isNotEmpty)
    for (final w in plan.windows)
      '${planWindowName(w)}: ${(w.used * 100).round()}% used'
          '${w.resetsAt == null ? '' : ' · resets ${_clock(w.resetsAt!.toLocal(), now ?? DateTime.now())}'}'
  else if (outsideLabel != null)
    'Plan limits: not reported by $outsideLabel',
];

/// The panel's Session info view: Environment, Context, Usage + limits, Running work and Changes.
class SessionInfoView extends ConsumerStatefulWidget {
  const SessionInfoView({super.key, required this.session});

  final CodeSessionInfo session;

  @override
  ConsumerState<SessionInfoView> createState() => _SessionInfoViewState();
}

class _SessionInfoViewState extends ConsumerState<SessionInfoView> {
  final _running = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final info = widget.session;
    final id = info.id;
    // The ⋯ menu's Background tasks, whether this view was showing or opens for it.
    ref.watch(consolePanelProvider(id).select((p) => p.runningSeq));
    if (ref.read(consolePanelProvider(id).notifier).takeRunningJump()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _running.currentContext;
        if (target != null) Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 200));
      });
    }
    final controller = ref.read(codeSessionProvider(id).notifier);
    // Only what Session info shows, not every streamed delta; the limit's inputs so [CodeSessionController.limitPick]
    // stays current.
    final (mode, inNativeMode, _, _, _, _, _) = ref.watch(
      codeSessionProvider(id).select(
        (s) => (
          s.mode,
          s.inNativeMode,
          s.changing,
          s.waited,
          s.switching,
          s.transcript.running,
          switch (s.transcript.items.lastOrNull) {
            NoticeItem(:final limit?) => limit,
            _ => null,
          },
        ),
      ),
    );
    final outside = isOutsideLead(info.harness, info.workingDir);
    final driver = ref.read(driverRegistryProvider).resolve(info.harness);
    final label = driver?.info.label ?? info.harness;
    final spec = ref.watch(modelCatalogProvider)[ModelId(info.model)];
    final totals = ref.watch(codeUsageProvider(id)).value ?? UsageTotals.zero;
    final project = ref.watch(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull?.path;
    final settings = ref.watch(codeSettingsProvider);

    // Not a lazy list: Background tasks scrolls to Running work, which must be built for that.
    return SingleChildScrollView(
      key: const ValueKey('console.info'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoSection(
            title: 'Environment',
            child: InfoRows(
              rows: environmentRows(
                harness: label,
                model: spec?.name ?? (info.model.isEmpty ? 'Default model' : info.model),
                fidelity: driver == null || inNativeMode ? null : fidelityNote(driver, mode),
                project: noLocalFolder(info.workingDir)
                    ? 'Demo'
                    : displayPath(project ?? info.workingDir, '', home: io.homeDir()),
                info: info,
                remote: ref.watch(sessionRemoteLineProvider),
              ),
            ),
          ),
          InfoSection(
            title: 'Context',
            child: ContextView(
              breakdown: contextRows(
                used: totals.contextTokens,
                limit: spec?.contextLength ?? 0,
                parts: ref.watch(codeContextPartsProvider(id)),
                outside: outside,
                autoCompactPercent: outside ? 0 : settings.autoCompactPercent,
              ),
            ),
          ),
          InfoSection(
            title: 'Usage and limits',
            trailing: AdaptiveButton(
              label: 'Edit cap',
              emphasis: ButtonEmphasis.plain,
              onPressed: () => showSettings(
                context,
                section: SettingsSection.code,
                anchor: 'budget',
                args: {'scope': SettingsScope.session.name, 'session': id},
              ),
            ),
            child: InfoLines(
              lines: usageLines(
                totals: totals,
                budget: settings.budgets[id],
                limit: controller.limitPick?.limit,
                plan: ref.watch(codePlanLimitsProvider(id)),
                outsideLabel: outside ? label : null,
              ),
            ),
          ),
          InfoSection(
            key: _running,
            title: 'Running work',
            child: RunningWork(session: info),
          ),
          if (info.diffTarget != null)
            InfoSection(
              title: 'Changes',
              child: _Changes(session: info),
            ),
        ],
      ),
    );
  }
}

/// One card of Session info.
class InfoSection extends StatelessWidget {
  const InfoSection({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: theme.type.callout.semibold.tint(theme.text))),
              ?trailing,
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class InfoRows extends StatelessWidget {
  const InfoRows({super.key, required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 108, child: Text(label, style: theme.type.caption.tint(theme.textMuted))),
                Expanded(child: Text(value, style: theme.type.caption.tint(theme.text))),
              ],
            ),
          ),
      ],
    );
  }
}

class InfoLines extends StatelessWidget {
  const InfoLines({super.key, required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(l, style: theme.type.caption.tint(theme.text)),
          ),
      ],
    );
  }
}

/// The context bar (only with a known window) and the breakdown rows; "≈" marks a size estimated from length.
class ContextView extends StatefulWidget {
  const ContextView({super.key, required this.breakdown});

  final ContextBreakdown breakdown;

  @override
  State<ContextView> createState() => _ContextViewState();
}

class _ContextViewState extends State<ContextView> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final (:used, :limit, :rows) = widget.breakdown;
    String size(int n, bool estimated) => '${estimated ? '≈' : ''}${formatTokens(n)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          limit > 0
              ? '${formatTokens(used)} of ${formatTokens(limit)} · ${(used / limit * 100).round()}% used'
              : used > 0
              ? '${formatTokens(used)} used · limit not reported'
              : 'Nothing used yet',
          style: theme.type.caption.medium.tint(theme.text),
        ),
        if (limit > 0) ...[
          const SizedBox(height: 6),
          ClipRRect(
            key: const ValueKey('console.context.bar'),
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: theme.border),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: (used / limit).clamp(0, 1).toDouble(),
                    child: ColoredBox(color: theme.accent),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 6),
        for (final row in rows) ...[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: row.children.isEmpty
                ? null
                : () => setState(() => _open.contains(row.label) ? _open.remove(row.label) : _open.add(row.label)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    child: row.children.isEmpty
                        ? null
                        : AdaptiveIcon(
                            _open.contains(row.label) ? EveryIcon.chevronDown : EveryIcon.chevronRight,
                            size: 10,
                            color: theme.textMuted,
                          ),
                  ),
                  Expanded(
                    child: Text(
                      row.note == null ? row.label : '${row.label} · ${row.note}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.caption.tint(theme.text),
                    ),
                  ),
                  Text(
                    size(row.tokens, row.estimated),
                    style: theme.type.caption
                        .tint(theme.textMuted)
                        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
          ),
          if (_open.contains(row.label))
            for (final c in row.children)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 1, 0, 1),
                child: Row(
                  children: [
                    Expanded(child: Text(c.name, style: theme.type.caption.tint(theme.textMuted))),
                    Text(size(c.tokens, row.estimated), style: theme.type.caption.tint(theme.textMuted)),
                  ],
                ),
              ),
        ],
        if (rows.any((r) => r.estimated)) ...[
          const SizedBox(height: 4),
          Text(
            '≈ estimated from length; the total is what the last call reported.',
            style: theme.type.micro.tint(theme.textMuted),
          ),
        ],
      ],
    );
  }
}

/// Session info → Changes: the totals (open the Diff) and the git button.
class _Changes extends ConsumerWidget {
  const _Changes({required this.session});

  final CodeSessionInfo session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final git = ref.watch(codeGitProvider(session.id)).value;
    final files = git?.files.length ?? 0;
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(consolePanelProvider(session.id).notifier).show(ConsoleView.diff),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: files == 0 ? 'No changes yet' : '$files file${files == 1 ? '' : 's'}  '),
                    if (files > 0) ...[
                      TextSpan(
                        text: '+${git!.added} ',
                        style: TextStyle(color: theme.success),
                      ),
                      TextSpan(
                        text: '−${git.removed}',
                        style: TextStyle(color: theme.danger),
                      ),
                    ],
                  ],
                ),
                style: theme.type.callout.tint(theme.text),
              ),
            ),
          ),
        ),
        GitButton(sessionId: session.id),
      ],
    );
  }
}
