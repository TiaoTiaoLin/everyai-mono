import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../chat/ui/chat_markdown.dart';

/// The bundled copy of the repository's `THIRD_PARTY_NOTICES.md` (a test
/// keeps the two the same).
const noticesAsset = 'assets/legal/THIRD_PARTY_NOTICES.md';

final thirdPartyNoticesProvider = FutureProvider<String>((ref) => rootBundle.loadString(noticesAsset));

/// Settings → About → Third-party notices.
class NoticesBody extends ConsumerWidget {
  const NoticesBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    return switch (ref.watch(thirdPartyNoticesProvider)) {
      AsyncData(:final value) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ChatMarkdown(value)),
        ),
      ),
      AsyncError() => Center(child: Text("Couldn't load the notices.", style: theme.type.body.tint(theme.textMuted))),
      _ => const SizedBox.shrink(),
    };
  }
}
