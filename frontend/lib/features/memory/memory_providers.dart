import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../../core/security/untrusted.dart';
import '../../core/providers.dart';
import '../chat/data/chat_repository.dart';
import '../skills/skills_providers.dart';
import 'data/chat_recall.dart';
import 'domain/memory.dart';

/// The client-executed tools for memory and chat recall (`client_tools`).
const memoryTool = 'memory';
const searchChatsTool = 'search_chats';
const localChatTools = {memoryTool, searchChatsTool};

/// Every tool [LocalChatTools] runs: memory, chat search and the skill tools.
const allLocalChatTools = {...localChatTools, ...skillChatTools};

final memoryProvider = NotifierProvider<MemoryController, Memory>(MemoryController.new);

/// The user's memory, saved in Preferences under [MemoryController.key].
final class MemoryController extends Notifier<Memory> {
  static const key = 'memory.v1';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  Memory build() => Memory.decode(ref.read(preferencesProvider)[key]);

  void _save(Memory next) {
    if (next == state) return;
    final dropped = MemoryTarget.values.any((t) => state.entries(t).any((e) => !next.entries(t).contains(e)));
    state = next;
    _prefs[key] = next.encode();
    // A removed or rewritten entry must not live on in chats' frozen copies:
    // they take a new one on their next turn (one prompt-cache miss).
    if (dropped) MemorySnapshots(_prefs).invalidate();
  }

  void setEnabled(bool enabled) => _save(state.copyWith(enabled: enabled));

  /// Runs one `memory` tool call and saves the result.
  MemoryEdit apply(Map<String, Object?> args) {
    final edit = applyMemoryEdit(state, args);
    if (!edit.isError) _save(edit.memory);
    return edit;
  }

  /// Settings → Memory: replaces a note's entries as the user edited them.
  /// Never refused (the user's own words); hidden characters are dropped.
  void setEntries(MemoryTarget target, List<String> entries) => _save(
    state.withEntries(target, [
      for (final e in entries.map((e) => normalizeEntry(stripHidden(e))))
        if (e.isNotEmpty) e,
    ]),
  );

  /// Empties both notes and drops every chat's frozen copy of them.
  void clear() {
    MemorySnapshots(_prefs).clearAll();
    _save(state.copyWith(user: const [], notes: const []));
  }

  /// The memory block for [chatId]: taken from the current notes on the
  /// chat's first turn, then the same text on every later turn.
  /// Nothing while memory is off, whatever the chat started with (a chat
  /// that begins while it is off stays without it).
  String? snapshotFor(String chatId) {
    final block = MemorySnapshots(_prefs).take(chatId, () => memoryBlock(state));
    return state.enabled ? block : null;
  }
}

/// Per-chat frozen memory blocks in Preferences. Chats point at a
/// content-addressed text (most chats share one), so storage stays small.
final class MemorySnapshots {
  MemorySnapshots(this._prefs);

  final Preferences _prefs;

  /// Per chat: the id of its block, or '' when it began without memory.
  static const chatPrefix = 'memory.chat.';
  static const _text = 'memory.snap.';
  static const _index = 'memory.snaps';

  /// The chat's snapshot, taking one with [current] if it has none (or its
  /// block was invalidated). Null when memory was off as the chat began, or
  /// the user cleared memory since.
  String? take(String chatId, String? Function() current) {
    if (_prefs['$chatPrefix$chatId'] case final id?) {
      if (id.isEmpty) return null;
      if (_prefs['$_text$id'] case final text?) return text;
    }
    final block = current();
    if (block == null) {
      _prefs['$chatPrefix$chatId'] = '';
      return null;
    }
    final id = fingerprint(block);
    _prefs['$_text$id'] = block;
    final ids = _ids();
    if (!ids.contains(id)) _prefs[_index] = jsonEncode([...ids, id]);
    _prefs['$chatPrefix$chatId'] = id;
    return block;
  }

  List<String> _ids() {
    try {
      return switch (jsonDecode(_prefs[_index] ?? '[]')) {
        final List<Object?> l => l.whereType<String>().toList(),
        _ => const [],
      };
    } on FormatException {
      return const [];
    }
  }

  void _dropTexts() {
    for (final id in _ids()) {
      _prefs['$_text$id'] = null;
    }
    _prefs[_index] = null;
  }

  /// Drops every stored block; chats that had one go on without memory.
  void clearAll() {
    _dropTexts();
    for (final k in _prefs.keysStartingWith(chatPrefix)) {
      _prefs[k] = '';
    }
  }

  /// Drops every stored block; chats that had one take a fresh one from the
  /// current notes on their next turn.
  void invalidate() {
    _dropTexts();
    for (final k in _prefs.keysStartingWith(chatPrefix)) {
      if (_prefs[k] != '') _prefs[k] = null;
    }
  }

  /// Forgets the chats [isGone] says were deleted, and the blocks no chat
  /// points at any more.
  void forgetChats(bool Function(String chatId) isGone) {
    for (final k in _prefs.keysStartingWith(chatPrefix)) {
      if (isGone(k.substring(chatPrefix.length))) _prefs[k] = null;
    }
    final used = {for (final k in _prefs.keysStartingWith(chatPrefix)) _prefs[k]};
    final ids = _ids();
    final kept = ids.where(used.contains).toList();
    if (kept.length == ids.length) return;
    for (final id in ids) {
      if (!used.contains(id)) _prefs['$_text$id'] = null;
    }
    _prefs[_index] = kept.isEmpty ? null : jsonEncode(kept);
  }
}

/// What a local tool call returns to the model.
typedef LocalToolResult = ({String text, bool isError});

/// Runs `memory`, `search_chats` and the skill tools on this device.
final class LocalChatTools {
  const LocalChatTools({required this.editMemory, required this.recall, this.skills});

  final MemoryEdit Function(Map<String, Object?> args) editMemory;
  final ChatRecall recall;

  /// `load_skill` and `read_skill_file`.
  final SkillChatTools? skills;

  bool handles(String name) => localChatTools.contains(name) || (skills?.handles(name) ?? false);

  /// Never throws: a failure is an error result the model can read.
  ///
  /// [readWeb]: the turn has read web content (search results or a fetched
  /// page), which may carry injected instructions. Memory lands in every
  /// later chat, so such a turn may not change it; the model asks the user
  /// and saves it in the next turn, once they confirm.
  ///
  /// [loadedSkills]: skills the chat already loaded (not sent again).
  Future<LocalToolResult> run(
    String name,
    String argumentsJson, {
    required String chatId,
    bool readWeb = false,
    Set<String> loadedSkills = const {},
  }) async {
    final Map<String, Object?> args;
    try {
      args = switch (jsonDecode(argumentsJson)) {
        final Map<String, Object?> m => m,
        _ => const {},
      };
    } on FormatException {
      return (text: 'Error: the arguments were not valid JSON.', isError: true);
    }
    if (skills case final s? when s.handles(name)) return s.run(name, args, loaded: loadedSkills);
    try {
      switch (name) {
        case memoryTool:
          if (readWeb) {
            return (
              text:
                  'Error: memory cannot be changed in a turn that read web content. Tell the user what you would '
                  'save; save it in a later turn if they confirm.',
              isError: true,
            );
          }
          final edit = editMemory(args);
          return (text: edit.text, isError: edit.isError);
        case searchChatsTool:
          if (args['chat_id'] case final String id when id.trim().isNotEmpty) {
            final text = await recall.readText(id.trim());
            return text == null
                ? (text: 'Error: no chat has chat_id "$id". Use a chat_id from search results.', isError: true)
                : (text: untrusted(text, source: 'chat:${id.trim()}'), isError: false);
          }
          final query = (args['query'] as String? ?? '').trim();
          if (query.isEmpty) return (text: 'Error: give a query or a chat_id.', isError: true);
          final limit = args['limit'] is num ? (args['limit'] as num).toInt() : 8;
          final found = await recall.searchText(query, excludeChat: chatId, limit: limit);
          return (text: untrusted(found, source: 'chat search'), isError: false);
      }
    } on Object catch (e) {
      return (text: 'Error: $name failed on the device ($e).', isError: true);
    }
    return (text: 'Error: unknown tool $name.', isError: true);
  }
}

final localChatToolsProvider = Provider<LocalChatTools>(
  (ref) => LocalChatTools(
    editMemory: (args) => ref.read(memoryProvider.notifier).apply(args),
    recall: ChatRecall(ref.watch(databaseProvider), ChatRepository(ref.watch(databaseProvider))),
    skills: ref.watch(skillChatToolsProvider),
  ),
);

/// The local tools the chat declares (`client_tools`): none when memory is off.
final enabledLocalChatToolsProvider = Provider<Set<String>>(
  (ref) => ref.watch(memoryProvider.select((m) => m.enabled)) ? localChatTools : const {},
);

/// The stored outcome of a local tool call ([ToolCallPart.resultJson]).
String localToolResultJson(LocalToolResult r) => jsonEncode({'text': r.text, 'error': r.isError});
