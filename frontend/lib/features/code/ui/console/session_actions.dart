import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/ui/adaptive.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart';

// What the user can do with a whole session, from its title menu in the console and its row in the session list.

Future<void> renameSession(BuildContext context, WidgetRef ref, CodeSessionInfo info) async {
  final title = await showAdaptivePrompt(
    context,
    title: 'Rename session',
    initialValue: info.title,
    confirmLabel: 'Rename',
  );
  if (title == null || title.trim().isEmpty) return;
  final now = ref.read(codeSessionsProvider.notifier).byId(info.id);
  if (now != null) ref.read(codeSessionsProvider.notifier).update(now.copyWith(title: title.trim()));
}

/// Saves the session as Markdown (to compare runs, or keep a record).
Future<void> exportSession(BuildContext context, WidgetRef ref, CodeSessionInfo info) async {
  final markdown = await ref.read(codeSessionProvider(info.id).notifier).exportMarkdown();
  if (markdown.isEmpty) return;
  final name = '${info.title}-${info.harness}'
      .replaceAll(RegExp(r'[^\w\- ]+'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '-');
  final location = await getSaveLocation(suggestedName: '$name.md');
  if (location == null) return;
  try {
    await XFile.fromData(Uint8List.fromList(utf8.encode(markdown)), mimeType: 'text/markdown').saveTo(location.path);
    if (context.mounted) showAdaptiveToast(context, 'Saved');
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, "Couldn't save: $e");
  }
}

/// Deletes the session (with its worktree, branch and checkpoints) once the user agrees; true when it is gone.
Future<bool> deleteSession(BuildContext context, WidgetRef ref, CodeSessionInfo info) async {
  final w = info.worktree;
  final ok = await showAdaptiveConfirm(
    context,
    title: 'Delete session?',
    message: w == null
        ? '"${info.title}" will be removed from your sessions.'
        : '"${info.title}" will be removed with its worktree, branch ${w.branch} and checkpoints. '
              'Work already merged stays merged.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!ok || !context.mounted) return false;
  try {
    if (w == null) {
      await ref.read(codeSessionsProvider.notifier).remove(info.id);
    } else {
      await ref.read(codeGitProvider(info.id).notifier).discard();
    }
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, "Couldn't delete the session: $e");
    return false;
  }
  return true;
}
