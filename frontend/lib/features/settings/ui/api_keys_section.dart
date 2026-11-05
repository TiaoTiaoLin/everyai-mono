import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/layout.dart';
import '../../../core/ui/every_icons.dart';
import '../byok_keys.dart';
import '../domain/byok_providers.dart';
import '../domain/key_check.dart';
import '../settings_registry.dart';
import 'settings_modal.dart';

/// Preferences → Add API keys: one card per provider whose key EveryAI can
/// use, and the Ultra spend cap on the user's keys. Keys stay in this
/// device's keychain; each request carries the one its model bills to.
class ApiKeysSection extends ConsumerWidget {
  const ApiKeysSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final keys = ref.watch(byokKeysProvider).value ?? const <String, String>{};
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Container(
          key: const ValueKey('byok.banner'),
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(theme.radius),
            border: Border.all(color: theme.accent.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AdaptiveIcon(EveryIcon.key, size: 18, color: theme.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Bring your own key', style: theme.type.body.semibold.tint(theme.text)),
                    const SizedBox(height: 2),
                    Text(
                      'Models your key covers bill to your provider account instead of EveryAI credits. Keys stay in '
                      'this device\'s keychain and go out only with the requests that use them. Pick the account per '
                      'model in the Model shop.',
                      style: theme.type.caption.tint(theme.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        for (final p in byokProviders)
          SettingsAnchor(
            section: SettingsSection.apiKeys,
            id: p.id,
            child: _ProviderCard(provider: p, savedKey: keys[p.id]),
          ),
        const SizedBox(height: 10),
        const _UltraCapRow(),
      ],
    );
  }
}

class _ProviderCard extends ConsumerStatefulWidget {
  const _ProviderCard({required this.provider, required this.savedKey});

  final ByokProvider provider;

  /// The saved key, or null when there is none.
  final String? savedKey;

  @override
  ConsumerState<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends ConsumerState<_ProviderCard> {
  bool _checking = false;

  /// The last check: the key it was for and whether it worked (null: unknown).
  ({String key, bool? valid})? _lastCheck;

  /// The saved key's check result, if it was checked.
  bool? get _works => _lastCheck != null && _lastCheck!.key == widget.savedKey ? _lastCheck!.valid : null;

  ByokProvider get provider => widget.provider;

  Future<void> _add() async {
    final key = await showAdaptivePrompt(
      context,
      title: '${provider.name} API key',
      confirmLabel: 'Save',
      obscureText: true,
      placeholder: provider.keyHint,
    );
    if (key == null || key.trim().isEmpty) return;
    try {
      await ref.read(byokKeysProvider.notifier).save(provider.id, key);
      if (mounted) showAdaptiveToast(context, '${provider.name} key saved');
      await _check();
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, "Couldn't save the key: $e");
    }
  }

  Future<void> _check() async {
    final key = ref.read(byokKeysProvider).value?[provider.id];
    if (key == null) return;
    setState(() => _checking = true);
    final result = await ref.read(keyCheckProvider)(provider, key);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _lastCheck = (key: key, valid: result.valid);
    });
    showAdaptiveToast(context, result.message);
  }

  Future<void> _remove() async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Remove the ${provider.name} key?',
      message: 'It is deleted from this device\'s keychain. Models billed to it go back to EveryAI credits.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (ok) await ref.read(byokKeysProvider.notifier).remove(provider.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final saved = widget.savedKey;
    final connected = saved != null;
    final status = !connected
        ? 'Not connected'
        : _works == false
        ? '•••• ${ByokKeys.lastFour(saved)} · rejected'
        : '•••• ${ByokKeys.lastFour(saved)}';
    return Container(
      key: ValueKey('byok.${provider.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(theme.radius),
        border: Border.all(color: theme.border),
      ),
      // On a narrow window the buttons go below the name instead of squeezing it.
      child: WrapRow(
        minLead: 200,
        lead: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Image.asset(provider.logo, width: 34, height: 34, fit: BoxFit.cover),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(provider.name, style: theme.type.body.medium.tint(theme.text)),
                  Text(provider.blurb, style: theme.type.caption.tint(theme.textMuted)),
                  Text(
                    status,
                    key: ValueKey('byok.${provider.id}.status'),
                    style: (connected ? theme.type.caption.mono : theme.type.caption).tint(
                      !connected
                          ? theme.textMuted
                          : _works == false
                          ? theme.danger
                          : theme.success,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (!connected) ...[
            AdaptiveButton(
              label: 'Get a key',
              emphasis: ButtonEmphasis.plain,
              onPressed: () => launchUrl(Uri.parse(provider.keysUrl), mode: LaunchMode.externalApplication),
            ),
            AdaptiveButton(
              key: ValueKey('byok.${provider.id}.add'),
              label: 'Add key',
              emphasis: ButtonEmphasis.secondary,
              onPressed: _add,
            ),
          ] else ...[
            AdaptiveButton(
              key: ValueKey('byok.${provider.id}.test'),
              label: _checking ? 'Testing…' : 'Test',
              emphasis: ButtonEmphasis.plain,
              onPressed: _checking ? null : _check,
            ),
            AdaptiveMenuButton(
              key: ValueKey('byok.${provider.id}.more'),
              actions: [
                MenuAction(label: 'Replace key', icon: EveryIcon.edit, onSelected: _add),
                MenuAction(label: 'Remove key', icon: EveryIcon.delete, destructive: true, onSelected: _remove),
              ],
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: AdaptiveIcon(EveryIcon.more, size: 15, color: theme.textMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Ultra on the user's own key always runs under a cap; this is the one a
/// session without its own budget gets.
class _UltraCapRow extends ConsumerWidget {
  const _UltraCapRow();

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final current = ref.read(byokUltraCapProvider);
    final raw = await showAdaptivePrompt(
      context,
      title: 'Ultra spend cap',
      confirmLabel: 'Save',
      initialValue: current.toStringAsFixed(2),
      placeholder: 'USD, e.g. 25',
    );
    if (raw == null) return;
    final usd = double.tryParse(raw.trim().replaceAll(r'$', ''));
    if (usd == null || usd <= 0) {
      if (context.mounted) showAdaptiveToast(context, 'Enter an amount above \$0.');
      return;
    }
    ref.read(byokUltraCapProvider.notifier).set(usd);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final cap = ref.watch(byokUltraCapProvider);
    return SettingsAnchor(
      section: SettingsSection.apiKeys,
      id: 'ultra-cap',
      child: Container(
        key: const ValueKey('byok.ultra-cap'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.surfaceRaised,
          borderRadius: BorderRadius.circular(theme.radius),
          border: Border.all(color: theme.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ultra spend cap', style: theme.type.body.medium.tint(theme.text)),
                  Text(
                    'Code\'s Ultra tier is open on your own key. A session stops when its upstream spend reaches its '
                    'budget, or this cap when it has none.',
                    style: theme.type.caption.tint(theme.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            AdaptiveButton(
              key: const ValueKey('byok.ultra-cap.edit'),
              label: '\$${cap.toStringAsFixed(2)}',
              emphasis: ButtonEmphasis.secondary,
              onPressed: () => _edit(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}
