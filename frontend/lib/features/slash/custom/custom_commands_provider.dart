import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../../core/ui/adaptive.dart';

import '../../code/code_providers.dart';
import '../../skills/domain/hidden_instructions.dart';
import 'command_store.dart';
import 'command_trust.dart';
import 'custom_command.dart';

/// Every custom command on disk: the global folder, then each Code project's
/// `.everyai/commands`. A project command shadows a global one by name (the
/// menu keeps the first of a name, so project entries come first).
final customCommandsProvider = AsyncNotifierProvider<CustomCommands, List<CustomCommand>>(CustomCommands.new);

final class CustomCommands extends AsyncNotifier<List<CustomCommand>> {
  @override
  Future<List<CustomCommand>> build() async {
    final projects = ref.watch(codeProjectsProvider);
    final all = await loadCustomCommands([for (final p in projects) (name: p.name, path: p.path)]);
    return [...all.where((c) => !c.isGlobal), ...all.where((c) => c.isGlobal)];
  }

  /// Re-reads the folders (after an edit in an outside editor).
  Future<void> reload() async {
    state = await AsyncValue.guard(build);
  }

  Future<CustomCommand> create(String name, {CodeProjectRef? project}) async {
    final c = await createCustomCommand(name: name, projectPath: project?.path, projectName: project?.name);
    await reload();
    return c;
  }

  Future<void> remove(CustomCommand command) async {
    await deleteCustomCommand(command);
    await reload();
  }
}

/// A project to put a command in.
typedef CodeProjectRef = ({String name, String path});

/// Which project commands are trusted. Preferences `code.commands`.
final commandTrustProvider = NotifierProvider<CommandTrustNotifier, CommandTrust>(CommandTrustNotifier.new);

final class CommandTrustNotifier extends Notifier<CommandTrust> {
  static const key = 'code.commands';

  @override
  CommandTrust build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const CommandTrust();
    try {
      return CommandTrust.fromJson(jsonDecode(raw));
    } on FormatException {
      return const CommandTrust();
    }
  }

  void set(CustomCommand c, bool trusted) {
    state = state.withTrust(c, trusted);
    ref.read(preferencesProvider)[key] = jsonEncode(state.toJson());
  }

  /// Shows the command and trusts it on a yes. Returns whether it is trusted now.
  Future<bool> review(BuildContext context, CustomCommand c) async {
    // The whole body, scrollable: trust is bound to the digest of all of it.
    // The detail is the body as the agent gets it, hidden characters removed; the findings show what was there.
    final flagged = c.findings.isNotEmpty;
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Trust /${c.name}?',
      message:
          'This command came with the project, in ${c.path ?? c.projectDir}. Running it sends this text to the '
          'agent as your message${c.mode != null ? ' and switches to ${c.mode} mode' : ''}.'
          '${flagged ? '\n\n${findingsMessage(c.findings)}' : ''}',
      detail: c.body,
      confirmLabel: flagged ? 'Trust anyway' : 'Trust and turn on',
    );
    if (ok) set(c, true);
    return ok;
  }
}
