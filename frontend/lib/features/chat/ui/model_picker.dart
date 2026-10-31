import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';

/// Composer chip showing the active model. Opens a picker with My models
/// (name + one-line description), a search over the whole shop, and a link to
/// the shop window.
class ModelChip extends ConsumerWidget {
  const ModelChip({super.key, required this.selected, required this.onSelected, this.enabled = true, this.pickerKey});

  final ModelSpec selected;
  final ValueChanged<ModelSpec> onSelected;
  final bool enabled;

  /// Lets the composer open the picker without a tap.
  final GlobalKey<AnchoredPopoverState>? pickerKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final chip = Semantics(
      button: true,
      label: 'Model: ${selected.name}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                selected.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.callout.medium.tint(theme.textMuted),
              ),
            ),
            const SizedBox(width: 3),
            AdaptiveIcon(EveryIcon.chevronDown, size: 12, color: theme.textMuted),
          ],
        ),
      ),
    );
    if (!enabled) return Opacity(opacity: 0.5, child: chip);
    return AnchoredPopover(
      key: pickerKey,
      width: 320,
      builder: (context, close) => _ModelPickerPanel(
        selected: selected,
        onSelected: (spec) {
          close();
          onSelected(spec);
        },
        onBrowse: () {
          close();
          context.go(Routes.models);
        },
      ),
      child: _HoverPill(child: chip),
    );
  }
}

class _ModelPickerPanel extends ConsumerStatefulWidget {
  const _ModelPickerPanel({required this.selected, required this.onSelected, required this.onBrowse});

  final ModelSpec selected;
  final ValueChanged<ModelSpec> onSelected;
  final VoidCallback onBrowse;

  @override
  ConsumerState<_ModelPickerPanel> createState() => _ModelPickerPanelState();
}

class _ModelPickerPanelState extends ConsumerState<_ModelPickerPanel> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final catalog = ref.watch(modelCatalogProvider);
    final library = ref.watch(libraryProvider).value ?? const <ModelSpec>[];
    final pinned = {...library, widget.selected}.toList();
    final q = _query.trim().toLowerCase();
    final matches = q.isEmpty
        ? const <ModelSpec>[]
        : catalog.all
              .where(
                (s) =>
                    !pinned.contains(s) &&
                    (s.name.toLowerCase().contains(q) ||
                        s.id.value.toLowerCase().contains(q) ||
                        s.provider.label.toLowerCase().contains(q) ||
                        s.provider.company.toLowerCase().contains(q)),
              )
              .take(20)
              .toList();

    Widget row(ModelSpec spec) => PopoverRow(
      leading: ModelAvatar(spec.provider, size: 20),
      title: spec.name,
      subtitle: spec.free ? 'Free' : null,
      trailing: spec == widget.selected ? AdaptiveIcon(EveryIcon.check, size: 15, color: theme.accent) : null,
      selected: spec == widget.selected,
      onTap: () => widget.onSelected(spec),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: AdaptiveTextField(
              placeholder: 'Search ${catalog.length} models',
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (q.isEmpty)
            for (final spec in pinned) row(spec)
          else if (matches.isEmpty && !pinned.any((s) => s.name.toLowerCase().contains(q)))
            PopoverRow(title: 'No models match "$_query"')
          else ...[
            for (final spec in pinned.where((s) => s.name.toLowerCase().contains(q))) row(spec),
            for (final spec in matches) row(spec),
          ],
          Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 6), color: theme.border),
          PopoverRow(
            title: 'Browse model shop…',
            leading: AdaptiveIcon(EveryIcon.models, size: 16, color: theme.textMuted),
            onTap: widget.onBrowse,
          ),
        ],
      ),
    );
  }
}

/// Subtle hover background for chips and pill buttons in the composer.
class _HoverPill extends StatefulWidget {
  const _HoverPill({required this.child});

  final Widget child;

  @override
  State<_HoverPill> createState() => _HoverPillState();
}

class _HoverPillState extends State<_HoverPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _hover ? theme.text.withValues(alpha: 0.07) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: widget.child,
      ),
    );
  }
}
