import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../artifact_providers.dart';
import '../../domain/artifact.dart';

/// A deck of flip cards: tap (or space) to flip, arrows to move, and mark each
/// card "Got it" or "Still learning". Progress is kept per deck
/// ([flashcardProgressProvider]), so it survives a restart.
class FlashcardsView extends ConsumerStatefulWidget {
  const FlashcardsView({super.key, required this.visual, this.height = 220});

  final Visual visual;
  final double height;

  @override
  ConsumerState<FlashcardsView> createState() => _FlashcardsViewState();
}

class _FlashcardsViewState extends ConsumerState<FlashcardsView> {
  bool _flipped = false;
  final _focus = FocusNode();

  FlashcardDeck get _deck => ref.read(flashcardProgressProvider(widget.visual.callId).notifier);

  List<(String, String)> get _cards => [
    for (final c in (widget.visual.args['cards'] as List<Object?>?) ?? const [])
      if (c case {'front': final String front, 'back': final String back}) (front, back),
  ];

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _go(int delta) {
    setState(() => _flipped = false);
    _deck.go(delta, _cards.length);
  }

  void _mark(bool known) {
    setState(() => _flipped = false);
    _deck.mark(known: known, count: _cards.length);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final cards = _cards;
    if (cards.isEmpty) return Text('No cards.', style: theme.type.body.tint(theme.textMuted));
    final progress = ref.watch(flashcardProgressProvider(widget.visual.callId));
    final index = progress.index.clamp(0, cards.length - 1);
    final (front, back) = cards[index];

    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.space) {
          setState(() => _flipped = !_flipped);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _go(1);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _go(-1);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () {
              _focus.requestFocus();
              setState(() => _flipped = !_flipped);
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: _flipped ? 1 : 0),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOutCubic,
                builder: (context, t, _) {
                  final showBack = t > 0.5;
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0012)
                      ..rotateY(math.pi * t + (showBack ? math.pi : 0)),
                    child: Container(
                      height: widget.height,
                      padding: const EdgeInsets.all(20),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: showBack ? theme.accent.withValues(alpha: 0.10) : theme.surfaceRaised,
                        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
                        border: Border.all(color: showBack ? theme.accent.withValues(alpha: 0.5) : theme.border),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              showBack ? 'ANSWER' : 'QUESTION',
                              style: theme.type.footnote.semibold.tint(theme.textMuted).copyWith(letterSpacing: 1.2),
                            ),
                            const SizedBox(height: 10),
                            if (showBack)
                              ChatMarkdown(back)
                            else
                              Text(front, textAlign: TextAlign.center, style: theme.type.title.tint(theme.text)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              AdaptiveIconButton(icon: EveryIcon.chevronLeft, tooltip: 'Previous card', onPressed: () => _go(-1)),
              Text(
                '${index + 1} / ${cards.length}',
                style: TextStyle(color: theme.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              AdaptiveIconButton(icon: EveryIcon.chevronRight, tooltip: 'Next card', onPressed: () => _go(1)),
              const Spacer(),
              Text(
                '${progress.known.length} known · ${progress.learning.length} learning',
                style: theme.type.caption.tint(theme.textMuted),
              ),
              const SizedBox(width: 10),
              AdaptiveButton(label: 'Still learning', emphasis: ButtonEmphasis.plain, onPressed: () => _mark(false)),
              AdaptiveButton(label: 'Got it', emphasis: ButtonEmphasis.secondary, onPressed: () => _mark(true)),
            ],
          ),
        ],
      ),
    );
  }
}
