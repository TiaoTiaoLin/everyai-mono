import '../../../core/ui/every_icons.dart';
import 'message.dart';

/// A chip under the new-chat composer: it starts the line and picks the
/// mode that suits the job (Learn teaches, Research sends researchers).
final class Starter {
  const Starter(this.icon, this.label, this.prompt, this.mode);

  final EveryIcon icon;
  final String label;

  /// Prefilled into the composer; the user finishes it.
  final String prompt;
  final ChatMode mode;
}

const chatStarters = <Starter>[
  Starter(EveryIcon.edit, 'Write', 'Help me write ', ChatMode.chat),
  Starter(EveryIcon.spark, 'Learn', 'Teach me ', ChatMode.learn),
  Starter(EveryIcon.chat, 'Code', 'Write code that ', ChatMode.chat),
  Starter(EveryIcon.globe, 'Research', 'Research ', ChatMode.research),
  Starter(EveryIcon.copy, 'Summarize', 'Summarize ', ChatMode.summarise),
];
