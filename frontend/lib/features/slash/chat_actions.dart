import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/ui/adaptive.dart';
import '../artifacts/export/downloads.dart';
import '../chat/chat_providers.dart';
import '../chat/domain/chat_session.dart';
import '../chat/domain/message.dart';
import '../chat/domain/reasoning_effort.dart';
import '../models/domain/model_catalog.dart';
import '../models/models_providers.dart';
import 'chat_commands.dart';
import 'skills/skill_draft.dart';
import 'slash_command.dart';
import '../settings/ui/settings_modal.dart';
import '../settings/settings_registry.dart';

/// The model best matching a typed name: an exact alias, else the first alias
/// starting with it (`sonnet` finds the newest Sonnet in the catalog).
ModelSpec? modelForQuery(ModelCatalog catalog, String query) {
  final q = query.trim().replaceFirst(RegExp(r'^@'), '');
  if (q.isEmpty) return null;
  return catalog.resolveMention(q) ?? catalog.mentionSuggestions(q).firstOrNull?.$2;
}

/// Wires the chat commands to one conversation. Callbacks that need a screen
/// ([context]) check it is still mounted after each await.
ChatSlashHost chatSlashHost(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  VoidCallback? openModelPicker,
}) {
  final provider = chatSessionProvider(conversationId);
  ChatController controller() => ref.read(provider.notifier);
  void toast(String message) {
    if (context.mounted) showAdaptiveToast(context, message);
  }

  return ChatSlashHost(
    setMode: (name) => controller().setMode(ChatMode.values.byName(name)),
    setModel: (query) {
      final spec = modelForQuery(ref.read(modelCatalogProvider), query);
      if (spec == null) return 'No model matches "$query".';
      if (ref.read(provider).phase.busy) return 'Wait for the answer to finish first.';
      controller().selectModel(spec);
      return 'Using ${spec.name}.';
    },
    openModelPicker: openModelPicker,
    setEffort: (name) {
      final effort = parseEffortArg(name);
      if (effort == null) return 'Pick one: auto, low, medium, high or max.';
      controller().setEffort(effort);
      return effort == ReasoningEffort.auto
          ? 'Thinking effort: the model decides.'
          : 'Thinking effort: ${effort.label}.';
    },
    sendWith: (text, {forceTool, context}) => controller().send(text, forceTool: forceTool, context: context),
    stage: (label, context) => controller().stageContext(context),
    newChat: () => context.go(Routes.newChat),
    retry: () {
      final s = ref.read(provider);
      if (s.phase.busy) return toast('Wait for the answer to finish first.');
      s.phase is Failed ? controller().retry() : controller().regenerate();
    },
    openMemory: () => showSettings(context, section: SettingsSection.memory),
    exportChat: (format) => exportChat(context, ref, conversationId, format),
    saveAsSkill: (hint) => saveChatAsSkill(context, ref, conversationId, hint),
  );
}

/// Saves the chat as `md`, `pdf` or `docx` through a save dialog.
Future<void> exportChat(BuildContext context, WidgetRef ref, String conversationId, String format) async {
  final f = format.trim().toLowerCase();
  final ext = switch (f) {
    '' || 'md' || 'markdown' => 'md',
    'pdf' => 'pdf',
    'docx' || 'word' => 'docx',
    _ => null,
  };
  if (ext == null) return showAdaptiveToast(context, 'Export as md, pdf or docx.');
  final state = ref.read(chatSessionProvider(conversationId));
  if (state.messages.isEmpty) return showAdaptiveToast(context, 'There is nothing to export yet.');
  final title = state.title ?? 'Chat';
  final markdown = chatToMarkdown(title, state.messages);
  final name = title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim().replaceAll(RegExp(r'\s+'), '-');
  final location = await getSaveLocation(suggestedName: '${name.isEmpty ? 'chat' : name}.$ext');
  if (location == null) return;
  try {
    final Uint8List bytes = switch (ext) {
      'pdf' => await pdfOf(title, markdown),
      'docx' => await docxOf(title, markdown),
      _ => Uint8List.fromList(utf8.encode(markdown)),
    };
    await File(location.path).writeAsBytes(bytes);
    if (context.mounted) showAdaptiveToast(context, 'Saved');
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, 'Could not save: $e');
  }
}

/// Asks the backend's cheap model to write a skill from the chat, checks it,
/// and saves it through the skill saver.
Future<void> saveChatAsSkill(BuildContext context, WidgetRef ref, String conversationId, String hint) async {
  final state = ref.read(chatSessionProvider(conversationId));
  if (state.messages.isEmpty) return showAdaptiveToast(context, 'There is nothing in this chat to learn from yet.');
  showAdaptiveToast(context, 'Writing a skill from this chat…');
  try {
    final skill = await ref
        .read(skillDrafterProvider)
        .draft(state.messages, hint: hint.trim(), session: conversationId);
    final saved = await ref.read(skillSaverProvider)(skill);
    if (context.mounted) showAdaptiveToast(context, 'Saved the skill "${saved.name}".');
  } on FormatException catch (e) {
    if (context.mounted) showAdaptiveToast(context, e.message);
  } on StateError catch (e) {
    if (context.mounted) showAdaptiveToast(context, e.message);
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, 'Could not write a skill: $e');
  }
}
