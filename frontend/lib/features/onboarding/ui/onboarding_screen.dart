import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/version.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/brand.dart';
import '../../../core/ui/segmented.dart';
import '../../../core/ui/every_icons.dart';
import '../../code/domain/code_session.dart' show everyaiHarnessName;
import '../../code/drivers/driver.dart';
import '../../code/drivers/driver_registry.dart';
import '../../code/code_settings_providers.dart';
import '../../code/ui/code_settings_section.dart' show harnessStatusLine;
import '../../settings/byok_keys.dart';
import '../../settings/domain/byok_providers.dart';
import '../../settings/domain/key_check.dart';
import '../onboarding_providers.dart';

/// The terms the last step asks the user to accept; the same text as
/// TERMS-DEV.md at the repo root.
const devBuildTerms = [
  'EveryAI is provided as-is, with no warranty, for testing only.',
  'You are responsible for your API keys and what they cost. EveryAI never stores your keys on its server.',
  'Outside agents (Claude Code, Codex, OpenCode, Gemini CLI) run under their own terms and your own accounts.',
  'Code runs commands and edits files in folders you open. Review what it does and use version control.',
  'Chats and sessions are stored on this device only, and a new build may not read old data.',
  'The software is licensed under FSL-1.1-ALv2 (see LICENSE).',
];

/// The pre-alpha entry screen: a short guided tour that ends with the user
/// accepting the dev-build terms. Shown once per [appVersion].
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.desktop});

  /// Whether the Code step lists the agents on this computer (desktops), or
  /// explains remote control (phones, tablets, web). Null: this host.
  final bool? desktop;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, bugs, keys, code, agree }

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _index = 0;
  bool _agreed = false;

  static const _steps = _Step.values;

  bool get _desktop => widget.desktop ?? Host.isDesktop;

  _Step get _step => _steps[_index];

  void _next() => setState(() => _index = (_index + 1).clamp(0, _steps.length - 1));
  void _back() => setState(() => _index = (_index - 1).clamp(0, _steps.length - 1));

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final last = _index == _steps.length - 1;
    return ColoredBox(
      color: theme.background,
      child: SafeArea(
        child: Column(
          children: [
            _ProgressBar(value: (_index + 1) / _steps.length),
            Padding(
              // On macOS the traffic lights sit in this row: start after them, as the sidebar does.
              padding: EdgeInsets.fromLTRB(Host.hasTrafficLights ? 92 : 28, 18, 28, 0),
              child: Row(
                children: [
                  const BrandMark(size: 22),
                  const SizedBox(width: 10),
                  Text('EveryAI', style: theme.type.headline.semibold.tint(theme.text)),
                  const Spacer(),
                  Text('$appVersion · pre-alpha', style: theme.type.caption.mono.tint(theme.textMuted)),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                    child: _StepView(
                      key: ValueKey(_step),
                      headline: _headline(_step),
                      child: switch (_step) {
                        _Step.welcome => const _Welcome(),
                        _Step.bugs => const _Bugs(),
                        _Step.keys => const _Keys(),
                        _Step.code => _desktop ? const _CodeHarnesses() : const _CodeRemote(),
                        _Step.agree => _Agree(agreed: _agreed, onChanged: (v) => setState(() => _agreed = v)),
                      },
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 22),
              child: Row(
                children: [
                  if (_index > 0)
                    AdaptiveButton(
                      key: const ValueKey('onboarding.back'),
                      label: 'Back',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: _back,
                    ),
                  const Spacer(),
                  if (_step == _Step.keys) ...[
                    AdaptiveButton(
                      key: const ValueKey('onboarding.skip'),
                      label: 'Skip for now',
                      emphasis: ButtonEmphasis.plain,
                      onPressed: _next,
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (last)
                    AdaptiveButton(
                      key: const ValueKey('onboarding.enter'),
                      label: 'Enter EveryAI',
                      icon: const AdaptiveIcon(EveryIcon.spark, size: 15),
                      onPressed: _agreed ? () => ref.read(onboardingAcceptedProvider.notifier).accept() : null,
                    )
                  else
                    AdaptiveButton(
                      key: const ValueKey('onboarding.next'),
                      label: switch (_step) {
                        _Step.welcome => 'Show me around',
                        _Step.bugs => 'Got it',
                        _ => 'Next',
                      },
                      onPressed: _next,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _headline(_Step step) => switch (step) {
    _Step.welcome => "Hi. You're early.",
    _Step.bugs => 'Things will break.',
    _Step.keys => 'Chat runs on your key.',
    _Step.code => _desktop ? 'Code works with the agents you already use.' : 'Code runs on your computer.',
    _Step.agree => 'One last thing.',
  };
}

/// A thin bar across the top showing how far along the tour is.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return SizedBox(
      height: 3,
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedFractionallySizedBox(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          widthFactor: value,
          child: ColoredBox(color: theme.primary),
        ),
      ),
    );
  }
}

/// A step: its headline types itself out, then the body fades in.
class _StepView extends StatefulWidget {
  const _StepView({super.key, required this.headline, required this.child});

  final String headline;
  final Widget child;

  @override
  State<_StepView> createState() => _StepViewState();
}

class _StepViewState extends State<_StepView> {
  bool _typed = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TypewriterText(
          widget.headline,
          style: theme.type.largeTitle.semibold.tint(theme.text),
          onDone: () => setState(() => _typed = true),
        ),
        const SizedBox(height: 18),
        AnimatedOpacity(
          opacity: _typed ? 1 : 0,
          duration: const Duration(milliseconds: 350),
          child: AnimatedSlide(
            offset: _typed ? Offset.zero : const Offset(0, 0.03),
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            // Not tappable until shown.
            child: IgnorePointer(ignoring: !_typed, child: widget.child),
          ),
        ),
      ],
    );
  }
}

/// Text that types itself out at about 30 characters a second, with a caret
/// while typing. A tap finishes it at once.
class TypewriterText extends StatefulWidget {
  const TypewriterText(this.text, {super.key, this.style, this.onDone});

  final String text;
  final TextStyle? style;
  final VoidCallback? onDone;

  static const perCharacter = Duration(milliseconds: 33);

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: TypewriterText.perCharacter * widget.text.length,
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone?.call();
    });
    unawaited(_controller.forward());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _controller.value = 1,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final shown = (widget.text.length * _controller.value).round();
        final typing = _controller.value < 1;
        return Semantics(
          label: widget.text,
          excludeSemantics: true,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: widget.text.substring(0, shown)),
                // The caret while typing; the rest keeps its space so lines don't reflow.
                if (typing)
                  TextSpan(
                    text: '▍',
                    style: TextStyle(color: EveryTheme.of(context).accent),
                  ),
                if (typing)
                  TextSpan(
                    text: widget.text.substring(shown),
                    style: const TextStyle(color: Color(0x00000000)),
                  ),
              ],
            ),
            style: widget.style,
          ),
        );
      },
    ),
  );
}

/// A line with an icon in front, for the bullet lists.
class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.child, this.tint});

  final EveryIcon icon;
  final Widget child;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AdaptiveIcon(icon, size: 17, color: tint ?? theme.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DefaultTextStyle.merge(style: theme.type.body.tint(theme.text), child: child),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Text(
      'This is a pre-alpha developer build of EveryAI: one workspace for chatting with any model and coding with '
      "any agent. It isn't finished, it isn't signed, and it changes every day. Here's what you need to know "
      'before you start.',
      style: theme.type.body.tint(theme.textMuted),
    );
  }
}

class _Bugs extends StatelessWidget {
  const _Bugs();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Point(
          icon: EveryIcon.shield,
          tint: theme.warning,
          child: const Text('Bugs are likely. Features can change or disappear between builds.'),
        ),
        const _Point(
          icon: EveryIcon.devices,
          child: Text(
            "Your chats and sessions live on this device only. Keep a copy of anything you can't lose: a new build "
            'may not read old data.',
          ),
        ),
        const _Point(
          icon: EveryIcon.globe,
          child: Text(
            'The dev server sleeps when nobody uses it. If you see "Waking up the EveryAI server…", give it a few '
            'seconds.',
          ),
        ),
        _Point(
          icon: EveryIcon.help,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Found something? Write it up as a GitHub issue: what you did, what you expected, what happened, and '
                'this version. Issues are public, so leave out keys and private data.',
              ),
              const SizedBox(height: 8),
              AdaptiveButton(
                key: const ValueKey('onboarding.report'),
                label: 'Open GitHub issues',
                emphasis: ButtonEmphasis.secondary,
                icon: const AdaptiveIcon(EveryIcon.external, size: 14),
                onPressed: () => launchUrl(bugReportUri(), mode: LaunchMode.externalApplication),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A new GitHub issue with the version and platform already filled in.
Uri bugReportUri() => Uri.parse(issuesUrl).replace(
  queryParameters: {
    'body':
        '**What I did**\n\n\n**What I expected**\n\n\n**What happened**\n\n\n'
        '---\nVersion: $appVersion\nPlatform: ${kIsWeb ? 'web' : defaultTargetPlatform.name}\n',
  },
);

/// Step 3: paste a key, checked live, saved to the keychain.
class _Keys extends ConsumerStatefulWidget {
  const _Keys();

  @override
  ConsumerState<_Keys> createState() => _KeysState();
}

class _KeysState extends ConsumerState<_Keys> {
  final _field = TextEditingController();
  ByokProvider _provider = byokProviders.first;
  bool _checking = false;
  KeyCheck? _result;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _field.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _checking = true;
      _result = null;
    });
    final result = await ref.read(keyCheckProvider)(_provider, key);
    // A rejected key isn't kept; "couldn't tell" (offline) is, with the reason shown.
    if (result.valid != false) await ref.read(byokKeysProvider.notifier).save(_provider.id, key);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
      if (result.valid != false) _field.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final saved = ref.watch(byokKeysProvider).value ?? const {};
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "No API keys come with this build: EveryAI doesn't pay for or see your model use. Add one to start "
          'chatting.',
          style: theme.type.body.tint(theme.textMuted),
        ),
        const SizedBox(height: 18),
        AdaptiveSegmented<ByokProvider>(
          values: byokProviders,
          selected: _provider,
          label: (p) => p.name,
          onSelected: (p) => setState(() {
            _provider = p;
            _result = null;
          }),
        ),
        const SizedBox(height: 6),
        Text(_provider.blurb, style: theme.type.caption.tint(theme.textMuted)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: AdaptiveTextField(
                key: const ValueKey('onboarding.key'),
                controller: _field,
                placeholder: saved.containsKey(_provider.id)
                    ? '${_provider.name} key saved (…${ByokKeys.lastFour(saved[_provider.id]!)}). Paste to replace.'
                    : _provider.keyHint,
                obscureText: true,
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            AdaptiveButton(
              key: const ValueKey('onboarding.key.save'),
              label: _checking ? 'Checking…' : 'Save',
              busy: _checking,
              onPressed: _checking ? null : _save,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (result != null)
          Row(
            key: const ValueKey('onboarding.key.result'),
            children: [
              AdaptiveIcon(
                result.valid == false ? EveryIcon.close : (result.valid == true ? EveryIcon.check : EveryIcon.info),
                size: 15,
                color: result.valid == false ? theme.danger : (result.valid == true ? theme.success : theme.warning),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.valid == false
                      ? '${result.message} It was not saved.'
                      : '${result.message}. Saved to this device\'s keychain.',
                  style: theme.type.callout.tint(theme.text),
                ),
              ),
            ],
          )
        else if (saved.isNotEmpty)
          Text(
            'Saved: ${[for (final p in byokProviders)
              if (saved.containsKey(p.id)) p.name].join(', ')}.',
            style: theme.type.callout.tint(theme.success),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AdaptiveButton(
              label: 'Get a ${_provider.name} key',
              emphasis: ButtonEmphasis.secondary,
              icon: const AdaptiveIcon(EveryIcon.external, size: 14),
              onPressed: () => launchUrl(Uri.parse(_provider.keysUrl), mode: LaunchMode.externalApplication),
            ),
            const AdaptiveButton(
              key: ValueKey('onboarding.local'),
              label: 'Use a local model (Ollama, LM Studio): coming soon',
              emphasis: ButtonEmphasis.plain,
              onPressed: null,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          "Your key stays in this device's keychain and is sent only with your own requests. It's never stored on "
          'our server. You can change it any time in Settings → API keys.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
      ],
    );
  }
}

/// Step 4 on a desktop: the coding CLIs found on this computer.
class _CodeHarnesses extends ConsumerWidget {
  const _CodeHarnesses();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final statuses = ref.watch(driverStatusesProvider);
    final own = ref.watch(codeSettingsProvider.select((s) => s.ownClis));
    final drivers = ref.watch(driverRegistryProvider).listed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'EveryAI drives the coding agents installed on this computer, on your own plans, and adds its workflows '
          'and checks on top. Here is what it found:',
          style: theme.type.body.tint(theme.textMuted),
        ),
        const SizedBox(height: 14),
        for (final d in drivers)
          _HarnessRow(
            key: ValueKey('onboarding.harness.${d.info.id}'),
            driver: d,
            status: switch (statuses) {
              AsyncData(:final value) => value[d.info.id],
              _ => null,
            },
            checking: statuses is! AsyncData,
            consented: own.contains(d.info.consentId),
            onConsent: (v) => ref.read(codeSettingsProvider.notifier).setOwnCli(d.info.consentId, v),
          ),
        const SizedBox(height: 8),
        Text(
          'Claude Code and Gemini CLI run on your own subscription, so EveryAI asks before using them. Change any of '
          'this in Settings → Code → Harnesses.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
      ],
    );
  }
}

class _HarnessRow extends StatelessWidget {
  const _HarnessRow({
    super.key,
    required this.driver,
    required this.status,
    required this.checking,
    required this.consented,
    required this.onConsent,
  });

  final HarnessDriver driver;
  final DriverStatus? status;
  final bool checking;
  final bool consented;
  final ValueChanged<bool> onConsent;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final id = driver.info.id;
    final own = id == everyaiHarnessName;
    final ready = own || (status?.installed ?? false);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: checking ? theme.textMuted : (ready ? theme.success : theme.border),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  own ? "EveryAI's own agent" : driver.info.label,
                  style: theme.type.callout.medium.tint(theme.text),
                ),
                Text(
                  own
                      ? 'Runs on the key from the last step'
                      : checking
                      ? 'Checking…'
                      : status == null
                      ? "Couldn't check"
                      : harnessStatusLine(id, status!),
                  style: theme.type.caption.tint(theme.textMuted),
                ),
              ],
            ),
          ),
          if (driver.info.needsConsent && ready)
            AdaptiveButton(
              key: ValueKey('onboarding.consent.$id'),
              label: consented ? 'In use ✓' : 'Use it',
              emphasis: consented ? ButtonEmphasis.secondary : ButtonEmphasis.primary,
              onPressed: () => onConsent(!consented),
            ),
        ],
      ),
    );
  }
}

/// Step 4 on phones, tablets and the web.
class _CodeRemote extends StatelessWidget {
  const _CodeRemote();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Text(
      'Coding agents run on your computer: install EveryAI there, then pair this device in Settings → Remote to '
      'follow and steer its sessions from here.',
      style: theme.type.body.tint(theme.textMuted),
    );
  }
}

/// Step 5: the terms and the checkbox that unlocks "Enter EveryAI".
class _Agree extends StatefulWidget {
  const _Agree({required this.agreed, required this.onChanged});

  final bool agreed;
  final ValueChanged<bool> onChanged;

  @override
  State<_Agree> createState() => _AgreeState();
}

class _AgreeState extends State<_Agree> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          key: const ValueKey('onboarding.agree'),
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onChanged(!widget.agreed),
          child: Semantics(
            checked: widget.agreed,
            button: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(
                    color: widget.agreed ? theme.primary : null,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: widget.agreed ? theme.primary : theme.border, width: 1.5),
                  ),
                  child: widget.agreed
                      ? Center(child: AdaptiveIcon(EveryIcon.check, size: 13, color: theme.onPrimary))
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "I understand this is an experimental pre-alpha build that may have bugs and lose data. I'll "
                    'use it for testing until it is stable, and I accept the Dev Build Terms.',
                    style: theme.type.body.tint(theme.text),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        AdaptiveButton(
          key: const ValueKey('onboarding.terms'),
          label: _open ? 'Hide the Dev Build Terms' : 'Read the Dev Build Terms',
          emphasis: ButtonEmphasis.plain,
          onPressed: () => setState(() => _open = !_open),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final t in devBuildTerms)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text('•  $t', style: theme.type.callout.tint(theme.textMuted)),
                        ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
