import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/memory.dart';
import '../memory_providers.dart';

/// Settings → Memory: turn memory on or off, and view, edit and clear what
/// the model saved. Everything here stays on this device.
class MemoryBody extends ConsumerWidget {
  const MemoryBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final memory = ref.watch(memoryProvider);
    final ctl = ref.read(memoryProvider.notifier);

    Future<void> edit(MemoryTarget target, {int? at}) async {
      final entries = memory.entries(target);
      final text = await showAdaptivePrompt(
        context,
        title: at == null ? 'Add to ${target.label}' : 'Edit entry',
        confirmLabel: 'Save',
        initialValue: at == null ? '' : entries[at],
      );
      if (text == null) return;
      final next = [...entries];
      if (at == null) {
        next.add(text);
      } else {
        next[at] = text;
      }
      ctl.setEntries(target, next);
    }

    Widget note(MemoryTarget target) {
      final entries = memory.entries(target);
      final size = Memory.sizeOf(entries);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdaptiveSectionHeader('${target.label} · $size/${target.limit}'),
          if (entries.isEmpty)
            AdaptiveListTile(title: Text('Nothing saved yet', style: theme.type.body.tint(theme.textMuted))),
          for (final (i, entry) in entries.indexed)
            AdaptiveListTile(
              title: Text(entry),
              onTap: () => edit(target, at: i),
              trailing: AdaptiveIconButton(
                icon: EveryIcon.delete,
                tooltip: 'Delete',
                onPressed: () => ctl.setEntries(target, [...entries]..removeAt(i)),
              ),
            ),
          if (size > target.limit)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Text(
                'Over the ${target.limit}-character limit: EveryAI can only add here after you shorten it.',
                style: theme.type.caption.tint(theme.warning),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: AdaptiveButton(
                label: 'Add entry',
                emphasis: ButtonEmphasis.secondary,
                icon: const AdaptiveIcon(EveryIcon.add, size: 14),
                onPressed: () => edit(target),
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        AdaptiveListTile(
          title: const Text('Use memory'),
          subtitle: const Text(
            'EveryAI keeps short notes about you and can search your earlier chats. '
            'Everything stays on this device.',
          ),
          trailing: AdaptiveSwitch(value: memory.enabled, onChanged: ctl.setEnabled),
        ),
        for (final t in MemoryTarget.values) note(t),
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            'Each chat keeps the notes it started with, so changes show up in your next chat.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: AdaptiveButton(
            label: 'Clear memory',
            emphasis: ButtonEmphasis.destructive,
            onPressed: memory.isEmpty
                ? null
                : () async {
                    final ok = await showAdaptiveConfirm(
                      context,
                      title: 'Clear memory?',
                      message: 'Both notes are emptied, and chats you already started stop using them.',
                      confirmLabel: 'Clear',
                      destructive: true,
                    );
                    if (ok) ctl.clear();
                  },
          ),
        ),
      ],
    );
  }
}
