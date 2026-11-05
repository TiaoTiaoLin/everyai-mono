import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_error.dart';
import '../../core/preferences.dart';
import '../../core/providers.dart';
import '../artifacts/checks/tool_checks.dart';
import '../attachments/attachment.dart';
import '../code/session_notifications.dart' show appFocusedProvider, systemNotifierProvider;
import '../memory/memory_providers.dart';
import '../models/domain/model_catalog.dart';
import '../models/models_providers.dart';
import '../skills/skills_providers.dart';
import '../usage/usage_totals.dart';
import 'data/chat_cleanup.dart';
import 'data/chat_repository.dart';
import 'data/chat_titles.dart';
import 'data/chat_transport.dart';
import 'domain/ask_user.dart';
import 'domain/chat_session.dart';
import 'domain/message.dart';
import 'domain/reasoning_effort.dart';
import 'domain/security_alert.dart';
import '../settings/byok_keys.dart' show modelBillingProvider;
import '../settings/reply_language.dart';

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final db = ref.watch(databaseProvider);
  return ChatRepository(db, afterDelete: () => sweepChatPreferences(db, ref.read(preferencesProvider)));
});

final chatTransportProvider = Provider<ChatTransport>((ref) {
  final api = ref.watch(apiClientProvider);
  // With dev auth the backend serves anonymous requests as its dev user.
  final authenticated = !ref.watch(appConfigProvider).devSkipAuth;
  return TransportRouter(
    stream: SseTransport(api, authenticated: authenticated),
    image: ImageTransport(api, authenticated: authenticated),
  );
});

/// Names new chats after their first reply. Null when chat turns don't go to
/// the backend (a fake transport in tests), so no title call goes out either.
final chatTitlerProvider = Provider<ChatTitler?>((ref) {
  if (ref.watch(chatTransportProvider) is! TransportRouter) return null;
  return HttpChatTitler(ref.watch(apiClientProvider), authenticated: !ref.watch(appConfigProvider).devSkipAuth);
});

/// Answers client-executed tool calls (`POST /v1/chat/tool_result`).
final toolResultsProvider = Provider<ToolResults>((ref) {
  return HttpToolResults(ref.watch(apiClientProvider), authenticated: !ref.watch(appConfigProvider).devSkipAuth);
});

/// UI tools the app runs itself and answers with [ChatController.resolveTool]
/// (sent as `client_tools`): the question card (`ask_user`).
final chatClientToolsProvider = Provider<Set<String>>(
  // …and the artifact and diagram checks (Mermaid errors, bad TeX).
  // …and, with memory on, the local memory and chat-search tools.
  // …and, when the user has skills for Chat, load_skill and read_skill_file.
  (ref) => {
    askUserTool,
    ...ref.watch(appToolCheckerProvider).tools,
    ...ref.watch(enabledLocalChatToolsProvider),
    if (ref.watch(chatSkillsProvider).isNotEmpty) ...skillChatTools,
  },
);

final conversationsProvider = StreamProvider<List<Conversation>>(
  (ref) => ref.watch(chatRepositoryProvider).watchConversations(),
);

/// One controller per conversation id. New chats get a fresh id up front, and the
/// row is created on first send, so the key never changes mid-turn.
final chatSessionProvider = NotifierProvider.autoDispose.family<ChatController, ChatSessionState, String>(
  ChatController.new,
);

final class ChatController extends Notifier<ChatSessionState> {
  ChatController(this.conversationId);

  final String conversationId;
  Completer<void>? _cancel;
  StreamSubscription<ChatEvent>? _turn;
  final _buffer = StringBuffer();
  final _reasoning = StringBuffer();

  /// The chat's local title and opening prompt, until its first reply asks
  /// the backend for a better title.
  ({String placeholder, String prompt, ModelSpec model})? _untitled;

  /// Stores a tool result on the turn in flight's call part (set per turn).
  void Function(String callId, String resultJson)? _recordResult;

  ChatRepository get _repo => ref.read(chatRepositoryProvider);
  ModelCatalog get _catalog => ref.read(modelCatalogProvider);

  @override
  ChatSessionState build() {
    ref.onDispose(() {
      _cancel?.complete();
      _turn?.cancel();
    });
    unawaited(_load());
    return ChatSessionState(
      conversationId: conversationId,
      model: ref.read(defaultModelProvider),
      effort: ReasoningEffort.parse(ref.read(preferencesProvider)[ReasoningEffort.prefKey(conversationId)]),
    );
  }

  Future<void> _load() async {
    final conversation = await _repo.conversation(conversationId);
    final messages = conversation == null ? const <Message>[] : await _repo.messages(conversationId);
    if (!ref.mounted) return;
    state = state.copyWith(
      title: conversation?.title,
      model: conversation == null ? null : _catalog[conversation.model] ?? state.model,
      messages: List.unmodifiable(messages),
      phase: const Idle(),
    );
  }

  /// Changes the conversation's model (the composer's model picker).
  void selectModel(ModelSpec model) {
    if (state.phase.busy) return;
    state = state.copyWith(model: model);
  }

  /// Idle/Failed → Awaiting. Ignored while a turn is in flight.
  /// While the turn waits on a question card, the text is the user's reply to it.
  ///
  /// [forceTool] makes the model's first call use that tool (the `/quiz`,
  /// `/slides`… commands); [context] is extra instructions (a loaded skill)
  /// sent with the prompt but not shown or saved with the message.
  Future<void> send(String input, {List<Attachment> attachments = const [], String? forceTool, String? context}) async {
    if (state.phase.busy) {
      final asked = state.pendingTools.where((t) => t.name == askUserTool).firstOrNull;
      if (asked != null && input.trim().isNotEmpty) {
        await answerQuestions(asked.id, AskUserOutcome.replied(input.trim()));
      }
      return;
    }
    if (state.phase is Loading) return;
    final (:model, :prompt) = parseMention(input, _catalog);
    if (prompt.isEmpty && attachments.isEmpty) return;
    // A forced tool needs tools on.
    if (forceTool != null) state = state.copyWith(toolsEnabled: true);
    final staged = _stagedContext;
    _stagedContext = null;
    await _startTurn(
      prompt: prompt,
      model: model ?? state.model,
      userText: input.trim(),
      attachments: [for (final a in attachments) AttachmentPart.of(a)],
      forceTool: forceTool,
      context: [?staged, ?context].join('\n\n'),
    );
  }

  /// Instructions held for the next message the user sends (`/<skill>`).
  String? _stagedContext;
  void stageContext(String context) => _stagedContext = context;

  void setMode(ChatMode mode) => state = state.copyWith(mode: mode);

  void setResearchDepth(ResearchDepth depth) => state = state.copyWith(researchDepth: depth);

  /// Asks the last question again in [mode] (the button the model offers
  /// with `suggest_mode`). The earlier answer stays above the new one.
  ///
  /// [model] answers this one turn instead of the chat's model: re-running
  /// an Auto answer uses the model Auto picked, so the server keeps the mode.
  Future<void> rerunIn(ChatMode mode, {ModelSpec? model}) async {
    if (state.phase.busy || state.phase is Loading) return;
    final last = state.messages.lastWhere((m) => m.isUser, orElse: () => state.messages.first);
    if (!last.isUser) return;
    setMode(mode);
    final (model: mentioned, :prompt) = parseMention(last.plainText, _catalog);
    await _startTurn(
      prompt: prompt,
      model: model ?? mentioned ?? state.model,
      userText: last.plainText.trim(),
      attachments: last.attachments,
    );
  }

  void setToolsEnabled(bool enabled) => state = state.copyWith(toolsEnabled: enabled);

  /// Sets the conversation's thinking effort, kept across restarts.
  void setEffort(ReasoningEffort effort) {
    state = state.copyWith(effort: effort);
    ref.read(preferencesProvider)[ReasoningEffort.prefKey(conversationId)] = effort.wire;
  }

  /// Idle/Failed → Awaiting: drops the last answer and asks again, optionally
  /// with a different model ("Retry with…").
  Future<void> regenerate({ModelSpec? model}) async {
    if (state.phase.busy || state.phase is Loading) return;
    final lastUser = state.messages.lastIndexWhere((m) => m.isUser);
    if (lastUser == -1) return;
    final dropped = state.messages.sublist(lastUser + 1);
    final previousModel = dropped.map((m) => m.model).nonNulls.map((id) => _catalog[id]).nonNulls.firstOrNull;
    state = state.copyWith(messages: List.unmodifiable(state.messages.take(lastUser + 1)));
    await _repo.deleteMessages(dropped.map((m) => m.id));
    final (model: mentioned, :prompt) = parseMention(state.messages[lastUser].plainText, _catalog);
    await _startTurn(prompt: prompt, model: model ?? previousModel ?? mentioned ?? state.model, userText: null);
  }

  /// Replaces a user message and everything after it, then answers the new text.
  Future<void> editAndResend(String userMessageId, String text) async {
    if (state.phase.busy || state.phase is Loading) return;
    final index = state.messages.indexWhere((m) => m.id == userMessageId);
    if (index == -1) return;
    final dropped = state.messages.sublist(index);
    // The edited message keeps its attachments.
    final attachments = dropped.first.attachments;
    state = state.copyWith(messages: List.unmodifiable(state.messages.take(index)), phase: const Idle());
    await _repo.deleteMessages(dropped.map((m) => m.id));
    final (:model, :prompt) = parseMention(text, _catalog);
    await _startTurn(prompt: prompt, model: model ?? state.model, userText: text.trim(), attachments: attachments);
  }

  /// Saves an artifact version the user made in the side panel (an edited
  /// drawing) as a `create_artifact` or `update_artifact` call marked
  /// `edited_by: user`, at the end of the chat, so the model sees it next
  /// turn. It joins the last answer, or a new assistant message when the chat
  /// does not end in a finished answer. False while a turn runs.
  Future<bool> saveUserArtifact(String toolName, Map<String, Object?> args) async {
    if (state.phase.busy || state.phase is Loading) return false;
    final part = ToolCallPart(
      toolName: toolName,
      argumentsJson: jsonEncode({...args, 'edited_by': 'user'}),
      callId: 'user-${_repo.newId()}',
    );
    final last = state.messages.lastOrNull;
    final message = last != null && !last.isUser && last.status == MessageStatus.complete
        ? last.copyWith(parts: [...last.parts, part])
        : Message(
            id: _repo.newId(),
            conversationId: conversationId,
            role: Role.assistant,
            parts: [part],
            createdAt: DateTime.now(),
          );
    state = state.copyWith(
      messages: List.unmodifiable([
        for (final m in state.messages)
          if (m.id != message.id) m,
        message,
      ]),
    );
    await _repo.saveMessage(message);
    return true;
  }

  /// Failed → Awaiting with the same prompt and model.
  Future<void> retry() async {
    if (state.phase case Failed(:final prompt, :final model)) {
      // Drop the failed assistant message. The user message stays.
      final messages = state.messages.where((m) => !(m.role == Role.assistant && m.status == MessageStatus.failed));
      state = state.copyWith(messages: List.unmodifiable(messages));
      await _startTurn(prompt: prompt, model: model, userText: null);
    }
  }

  /// Answers a client-executed tool call of the turn in flight ([ToolWait] in
  /// [ChatSessionState.pendingTools]). [result] is a string or any JSON;
  /// [isError] says the app could not run it. False when the call isn't
  /// pending or the server no longer waits for it (timed out, turn over).
  Future<bool> resolveTool(String callId, Object? result, {bool isError = false}) async {
    if (!state.pendingTools.any((t) => t.id == callId)) return false;
    _settleTool(callId);
    return ref.read(toolResultsProvider).resolve(callId, result, isError: isError);
  }

  /// Answers a pending `ask_user` card: the outcome is kept on its part (so
  /// the card shows it and later turns see it) and goes back to the model.
  Future<bool> answerQuestions(String callId, AskUserOutcome outcome) async {
    final wait = state.pendingTools.where((t) => t.id == callId && t.name == askUserTool).firstOrNull;
    if (wait == null) return false;
    final questions = askUserQuestions(
      ToolCallPart(toolName: wait.name, argumentsJson: wait.argumentsJson, callId: wait.id),
    );
    _recordResult?.call(callId, outcome.toJson());
    return resolveTool(callId, outcome.resultFor(questions));
  }

  /// A live security alert also goes out as an OS notification when the app
  /// is behind other windows; a critical one always does. Reopened chats
  /// don't notify again (only the stream calls this). The helper lives with
  /// Code's notifications: macOS and Linux only for now.
  void _notifySecurity(String argumentsJson) {
    final alert = SecurityAlert.fromJson(argumentsJson);
    if (alert.severity != SecuritySeverity.critical && ref.read(appFocusedProvider)()) return;
    unawaited(ref.read(systemNotifierProvider).show(alert.severity.label, alert.what));
  }

  /// Answers a call the app checks itself (a diagram, an artifact's math)
  /// with what the check found.
  Future<void> _answerCheck(ToolWait wait) async {
    final check = await ref.read(appToolCheckerProvider).check(wait.name, wait.argumentsJson, history: state.messages);
    if (!ref.mounted) return;
    try {
      await resolveTool(wait.id, check.text, isError: check.isError);
    } on Object {
      // The turn ended or the server stopped waiting; it times out on its own.
    }
  }

  /// Answers a `memory` or `search_chats` call on this device; the outcome is
  /// kept on its part for the chip.
  Future<void> _answerLocal(ToolWait wait) async {
    final result = await ref
        .read(localChatToolsProvider)
        .run(
          wait.name,
          wait.argumentsJson,
          chatId: conversationId,
          readWeb: state.liveSources.isNotEmpty,
          loadedSkills: loadedSkillsIn([
            for (final m in state.messages) ...m.parts.whereType<ToolCallPart>(),
            ...state.liveParts.whereType<ToolCallPart>(),
          ]),
        );
    if (!ref.mounted) return;
    _recordResult?.call(wait.id, localToolResultJson(result));
    try {
      await resolveTool(wait.id, result.text, isError: result.isError);
    } on Object {
      // The turn ended or the server stopped waiting; it times out on its own.
    }
  }

  void _settleTool(String callId) {
    if (!ref.mounted) return;
    state = state.copyWith(pendingTools: List.unmodifiable(state.pendingTools.where((t) => t.id != callId)));
  }

  /// Awaiting/Streaming → Idle, keeping whatever text arrived.
  void cancel() {
    if (!state.phase.busy) return;
    _cancel?.complete();
  }

  /// [userText] null: answer the last user message again (retry, regenerate).
  Future<void> _startTurn({
    required String prompt,
    required ModelSpec model,
    required String? userText,
    List<AttachmentPart> attachments = const [],
    String? forceTool,
    String context = '',
  }) async {
    if (state.title == null) {
      final c = await _repo.createConversationWithId(
        id: conversationId,
        title: titleFromPrompt(prompt.isNotEmpty ? prompt : attachments.firstOrNull?.name ?? 'Attachment'),
        model: state.model.id,
      );
      if (!ref.mounted) return;
      state = state.copyWith(title: c.title);
      _untitled = (placeholder: c.title, prompt: prompt, model: model);
    }

    // The user's skills: a catalog after the memory block, loaded on demand.
    final skills = state.toolsEnabled ? await chatSkillsNow(ref) : const <ChatSkill>[];
    if (!ref.mounted) return;

    var history = state.messages;
    if (userText == null) {
      // The last user message is the prompt; it isn't history too.
      final last = history.lastIndexWhere((m) => m.isUser);
      if (last != -1) {
        attachments = history[last].attachments;
        history = history.sublist(0, last);
      }
    }
    final messages = [...state.messages];
    if (userText != null) {
      final user = Message(
        id: _repo.newId(),
        conversationId: conversationId,
        role: Role.user,
        parts: [...attachments, if (userText.isNotEmpty) TextPart(userText)],
        createdAt: DateTime.now(),
      );
      messages.add(user);
      unawaited(_repo.saveMessage(user));
    }
    final assistant = Message(
      id: _repo.newId(),
      conversationId: conversationId,
      role: Role.assistant,
      parts: const [],
      createdAt: DateTime.now(),
      model: model.id,
      status: MessageStatus.streaming,
    );
    messages.add(assistant);

    _buffer.clear();
    _reasoning.clear();
    final cancel = _cancel = Completer<void>();
    state = state.copyWith(
      messages: List.unmodifiable(messages),
      phase: Awaiting(assistant.id),
      streamingText: '',
      liveSources: const [],
      liveParts: const [],
      streamingReasoning: '',
      toolStatus: '',
      liveTools: const [],
      pendingTools: const [],
    );

    // Segments in arrival order: text before a tool call, the call, more text…
    final parts = <MessagePart>[];
    var sources = const <Source>[];
    var followUps = const <String>[];
    var usage = UsageTotals.zero;
    void flushText() {
      if (_buffer.isEmpty) return;
      parts.add(TextPart(_buffer.toString()));
      _buffer.clear();
    }

    _recordResult = (callId, resultJson) {
      final at = parts.indexWhere((p) => p is ToolCallPart && p.callId == callId);
      if (at < 0 || !ref.mounted) return;
      final call = parts[at] as ToolCallPart;
      parts[at] = ToolCallPart(
        toolName: call.toolName,
        argumentsJson: call.argumentsJson,
        callId: call.callId,
        resultJson: resultJson,
      );
      state = state.copyWith(liveParts: List.unmodifiable(parts));
    };

    List<MessagePart> collect() {
      flushText();
      return [
        if (_reasoning.isNotEmpty) ReasoningPart(_reasoning.toString()),
        if (sources.isNotEmpty) SourcesPart(sources),
        ...parts,
        if (followUps.isNotEmpty) FollowUpsPart(followUps),
        if (!usage.isEmpty) UsagePart(usage),
      ];
    }

    final events = ref
        .read(chatTransportProvider)
        .send(
          ChatRequest(
            model: model,
            prompt: context.isEmpty ? prompt : '$context\n\n$prompt',
            history: history,
            mode: state.mode,
            conversationId: conversationId,
            toolsEnabled: state.toolsEnabled,
            attachments: attachments,
            clientTools: state.toolsEnabled ? ref.read(chatClientToolsProvider) : const {},
            memory: ref.read(memoryProvider.notifier).snapshotFor(conversationId),
            skills: skillCatalogBlock(skills),
            effort: state.effort.wireFor(model),
            replyLanguage: ref.read(replyLanguageProvider.notifier).wire,
            forceTool: state.toolsEnabled ? forceTool : null,
            providerKeys: ref.read(modelBillingProvider).headersFor(model.id),
            researchDepth: state.researchDepth,
          ),
          cancel: cancel.future,
        );

    _turn = events.listen(
      (event) {
        switch (event) {
          case TextDelta(:final text):
            _buffer.write(text);
            state = state.copyWith(phase: Streaming(assistant.id), streamingText: _buffer.toString(), toolStatus: '');
          case ReasoningDelta(:final text):
            _reasoning.write(text);
            state = state.copyWith(streamingReasoning: _reasoning.toString());
          case ImageOutput(:final bytes, :final mimeType, :final imageId, :final prompt, :final revises):
            flushText();
            parts.add(ImagePart(bytes: bytes, mimeType: mimeType, imageId: imageId, prompt: prompt, revises: revises));
            state = state.copyWith(
              phase: Streaming(assistant.id),
              liveParts: List.unmodifiable(parts),
              streamingText: '',
            );
          case UiToolCall(:final id, :final name, :final argumentsJson):
            flushText();
            parts.add(ToolCallPart(toolName: name, argumentsJson: argumentsJson, callId: id));
            state = state.copyWith(
              phase: Streaming(assistant.id),
              liveParts: List.unmodifiable(parts),
              streamingText: '',
            );
            if (name == securityAlertTool) _notifySecurity(argumentsJson);
          case final ToolWait wait:
            flushText();
            parts.add(ToolCallPart(toolName: wait.name, argumentsJson: wait.argumentsJson, callId: wait.id));
            state = state.copyWith(
              phase: Streaming(assistant.id),
              liveParts: List.unmodifiable(parts),
              streamingText: '',
              pendingTools: List.unmodifiable([...state.pendingTools, wait]),
            );
            if (ref.read(appToolCheckerProvider).handles(wait.name)) unawaited(_answerCheck(wait));
            if (ref.read(localChatToolsProvider).handles(wait.name)) unawaited(_answerLocal(wait));
          // The server stopped waiting (answered elsewhere, or timed out). A
          // question card shows its own state, and a checked visual its own
          // card, so neither gets a step row.
          case ToolProgress(:final id, :final name)
              when state.pendingTools.any((t) => t.id == id) ||
                  name == askUserTool ||
                  allLocalChatTools.contains(name) ||
                  ref.read(appToolCheckerProvider).handles(name):
            _settleTool(id);
          case ToolProgress(:final id, :final name, :final status, :final detail):
            final step = LiveToolStep(id: id, name: name, status: status, detail: detail);
            final tools = [...state.liveTools];
            final at = tools.indexWhere((t) => t.id == id);
            if (at < 0) {
              tools.add(step);
            } else {
              // Done events may omit the detail the running one carried.
              tools[at] = LiveToolStep(id: id, name: name, status: status, detail: detail ?? tools[at].detail);
            }
            state = state.copyWith(
              toolStatus: status == ToolRunStatus.running ? toolStatusLabel(name, detail) : '',
              liveTools: List.unmodifiable(tools),
            );
          case SourcesFound(sources: final found):
            sources = List.unmodifiable([...sources, ...found]);
            state = state.copyWith(liveSources: sources);
          case final UsageReport r:
            usage = usage.addCall(
              prompt: r.promptTokens,
              completion: r.completionTokens,
              cached: r.cachedTokens,
              cacheWrite: r.cacheWriteTokens,
              charged: r.chargedMicros,
              ownKey: r.ownKeyMicros,
              context: !r.followUps,
            );
            state = state.copyWith(liveUsage: usage);
          // Auto's pick: kept on the answer for its chip (the header finds it among the parts).
          case RouteChosen(model: final routed, :final mode, :final toolsEnabled):
            parts.removeWhere((p) => p is RoutePart);
            parts.insert(0, RoutePart(model: routed, mode: mode, toolsEnabled: toolsEnabled));
            state = state.copyWith(liveParts: List.unmodifiable(parts));
          case FollowUpsSuggested(:final questions):
            followUps = questions;
          case TurnDone():
            break;
        }
      },
      onError: (Object error) {
        final apiError = error is ApiError ? error : ProtocolError('$error');
        if (apiError is CancelledError || cancel.isCompleted) {
          _finish(assistant, collect(), MessageStatus.cancelled, phase: const Idle());
        } else {
          _finish(
            assistant,
            collect(),
            MessageStatus.failed,
            error: apiError.message,
            phase: Failed(apiError, prompt: prompt, model: model),
          );
        }
      },
      onDone: () {
        if (state.phase is Failed || !state.phase.busy) return;
        _finish(
          assistant,
          collect(),
          cancel.isCompleted ? MessageStatus.cancelled : MessageStatus.complete,
          phase: const Idle(),
        );
      },
      cancelOnError: true,
    );
  }

  void _finish(
    Message assistant,
    List<MessagePart> parts,
    MessageStatus status, {
    String? error,
    required TurnPhase phase,
  }) {
    if (!ref.mounted) return;
    final finished = assistant.copyWith(parts: parts, status: status, error: error);
    state = state.copyWith(
      messages: List.unmodifiable([for (final m in state.messages) m.id == assistant.id ? finished : m]),
      phase: phase,
      streamingText: '',
      liveSources: const [],
      liveParts: const [],
      streamingReasoning: '',
      toolStatus: '',
      liveTools: const [],
      pendingTools: const [],
      liveUsage: UsageTotals.zero,
    );
    _turn = null;
    _cancel = null;
    if (status != MessageStatus.failed || finished.parts.isNotEmpty) {
      unawaited(_repo.saveMessage(finished));
    }
    if (status == MessageStatus.complete && _untitled != null) {
      unawaited(_retitle(_untitled!, finished.plainText));
      _untitled = null;
    }
  }

  /// Swaps the local title for the backend's once the first reply is in.
  /// Keeps the local one on any failure, and a title the user changed meanwhile.
  Future<void> _retitle(({String placeholder, String prompt, ModelSpec model}) untitled, String reply) async {
    final titler = ref.read(chatTitlerProvider);
    if (titler == null || untitled.prompt.trim().isEmpty) return;
    final repo = _repo;
    final title = await titler.title(
      user: untitled.prompt,
      assistant: reply,
      session: conversationId,
      headers: ref.read(modelBillingProvider).headersFor(untitled.model.id),
    );
    if (title == null || title == untitled.placeholder) return;
    final renamed = await repo.renameIf(conversationId, from: untitled.placeholder, to: title);
    if (renamed && ref.mounted) state = state.copyWith(title: title);
  }
}

/// The status line shown while a server tool runs.
String toolStatusLabel(String tool, String? detail) => switch (tool) {
  'web_fetch' => 'Reading ${Uri.tryParse(detail ?? '')?.host ?? 'the page'}…',
  'generate_image' => 'Creating an image…',
  'summarise_parts' => 'Reading a long source${detail == null || detail.isEmpty ? '' : ' · $detail'}…',
  _ => 'Working…',
};
