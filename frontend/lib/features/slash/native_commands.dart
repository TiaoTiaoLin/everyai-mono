import '../../core/ui/adaptive.dart';
import '../code/harness/harness.dart';
import 'slash_command.dart';

/// An outside harness's own commands as `/` menu entries. Picking or typing
/// one hands `/name args` to [run] (the session's `runNativeCommand`); its
/// message, when it couldn't run, is shown. A command takes its arguments in
/// the box only when the harness gave a hint for them.
List<SlashCommand> nativeSlashCommands(
  List<NativeCommand> commands,
  Future<String?> Function(String name, String args) run,
) => [
  for (final c in commands)
    SlashCommand(
      name: c.name,
      description: c.description,
      argsHint: c.argsHint,
      group: SlashGroup.native,
      scope: SlashScope.code,
      run: (ctx, args) async {
        final message = await run(c.name, args);
        if (message != null && ctx.context.mounted) showAdaptiveToast(ctx.context, message);
      },
    ),
];
