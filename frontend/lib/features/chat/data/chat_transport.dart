import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/net/api_client.dart';
import '../../../core/net/api_error.dart';
import '../../artifacts/domain/artifact.dart';
import '../../artifacts/domain/drawing.dart';
import '../../attachments/attachment.dart';
import '../../models/domain/model_catalog.dart';
import '../../skills/domain/chat_skills.dart';
import '../domain/ask_user.dart';
import '../domain/image_refs.dart';
import '../domain/message.dart';

/// What the client sends for one assistant turn.
@immutable
final class ChatRequest {
  const ChatRequest({
    required this.model,
    required this.prompt,
    this.history = const [],
    this.mode = ChatMode.chat,
    this.conversationId,
    this.toolsEnabled = true,
    this.attachments = const [],
    this.clientTools = const {},
    this.memory,
    this.skills,
    this.effort,
    this.replyLanguage,
    this.forceTool,
    this.researchDepth = ResearchDepth.standard,
    this.providerKeys = const {},
  });

  final ModelSpec model;

  /// The user's own key for [model], as its request header
  /// (`ModelBilling.headersFor`); empty when EveryAI credits pay.
  final Map<String, String> providerKeys;
  final String prompt;

  /// Files sent with [prompt].
  final List<AttachmentPart> attachments;
  final ChatMode mode;

  /// Prior turns, oldest first.
  final List<Message> history;

  /// Sent as `session` so usage can be attributed to the conversation.
  final String? conversationId;

  /// Lets the model use tools (artifacts, charts, quizzes, web fetch, images).
  final bool toolsEnabled;

  /// UI tools the app runs itself: the server sends them as [ToolWait] and
  /// holds the turn until [ToolResults.resolve] answers (or it times out).
  final Set<String> clientTools;

  /// The chat's frozen memory block (the same text every turn), or null.
  final String? memory;

  /// The user's skills as a `<skills>` catalog (sorted, stable), or null.
  final String? skills;

  /// Thinking effort (`low|medium|high|max`); null leaves the model's default.
  final String? effort;

  /// The language replies and follow-ups must use ("French"); null follows
  /// the user's own message.
  final String? replyLanguage;

  /// A tool the model must call first (`make_quiz`…); later calls of the turn are free.
  final String? forceTool;

  /// Sent in Research mode.
  final ResearchDepth researchDepth;
}

/// Incremental output of one assistant turn.
sealed class ChatEvent {
  const ChatEvent();
}

final class TextDelta extends ChatEvent {
  const TextDelta(this.text);
  final String text;
}

/// The model's thinking, shown collapsed.
final class ReasoningDelta extends ChatEvent {
  const ReasoningDelta(this.text);
  final String text;
}

/// A generated image. [imageId] is its id in the conversation (`img_<n>`);
/// [revises] the image it is a new version of.
final class ImageOutput extends ChatEvent {
  const ImageOutput(this.bytes, this.mimeType, {this.imageId, this.prompt, this.revises});
  final Uint8List bytes;
  final String mimeType;
  final String? imageId;
  final String? prompt;
  final String? revises;
}

/// New sources, to append after the ones already received.
final class SourcesFound extends ChatEvent {
  const SourcesFound(this.sources);
  final List<Source> sources;
}

/// A UI tool call (quiz, chart, artifact, …) for the app to render.
final class UiToolCall extends ChatEvent {
  const UiToolCall({required this.id, required this.name, required this.argumentsJson});
  final String id;
  final String name;
  final String argumentsJson;
}

/// A client-executed tool call: the turn waits until the app answers it with
/// [ToolResults.resolve]. A [ToolProgress] with the same id (done, or failed
/// with detail "timed out") ends the wait.
final class ToolWait extends ChatEvent {
  const ToolWait({required this.id, required this.name, required this.argumentsJson});
  final String id;
  final String name;
  final String argumentsJson;
}

enum ToolRunStatus { running, done, failed }

/// Progress of a tool the server runs itself (web_fetch, generate_image).
final class ToolProgress extends ChatEvent {
  const ToolProgress({required this.id, required this.name, required this.status, this.detail});
  final String id;
  final String name;
  final ToolRunStatus status;
  final String? detail;
}

/// Tokens and the charge for one upstream call (a turn may make several).
final class UsageReport extends ChatEvent {
  const UsageReport({
    required this.promptTokens,
    required this.completionTokens,
    required this.cachedTokens,
    required this.chargedMicros,
    this.ownKeyMicros = 0,
    this.cacheWriteTokens = 0,
    this.model,
    this.followUps = false,
  });
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;
  final int cacheWriteTokens;
  final String? model;

  /// A side call (follow-up suggestions, a web search): costs money, doesn't fill the context.
  final bool followUps;

  /// What the user was charged, in millionths of a dollar.
  final int chargedMicros;

  /// What the call cost upstream on the user's own key (they pay it there).
  final int ownKeyMicros;
}

/// What EveryAI · Auto picked for this turn; comes before anything else.
final class RouteChosen extends ChatEvent {
  const RouteChosen({required this.model, required this.mode, required this.toolsEnabled});
  final ModelId model;
  final ChatMode mode;
  final bool toolsEnabled;
}

final class FollowUpsSuggested extends ChatEvent {
  const FollowUpsSuggested(this.questions);
  final List<String> questions;
}

final class TurnDone extends ChatEvent {
  const TurnDone();
}

/// Moves chat turns over the wire. Cancellation: complete [cancel] to abort the
/// HTTP request. The stream then ends with a [CancelledError].
abstract interface class ChatTransport {
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel});
}

/// Image-output models: `POST /v1/images` with the prompt, one image back.
final class ImageTransport implements ChatTransport {
  const ImageTransport(this._api, {this.authenticated = false});

  final ApiClient _api;
  final bool authenticated;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) async* {
    final json = await _api.postJson(
      'v1/images',
      {
        'model': request.model.id.value,
        'prompt': request.prompt,
        // Attached images are what to edit or follow.
        'input_references': [for (final r in imageRefsIn(const [], pending: request.attachments)) ?r.dataUrl],
      },
      authenticated: authenticated,
      timeout: ApiClient.generationTimeout,
      cancel: cancel,
      headers: request.providerKeys,
    );
    if (json case {'mime': final String mime, 'data': final String data}) {
      yield ImageOutput(
        base64Decode(data),
        mime,
        imageId: nextImageId(imageRefsIn(request.history)),
        prompt: request.prompt,
      );
      yield const TurnDone();
    } else {
      throw const ProtocolError('The image response had no image.');
    }
  }
}

/// Token streaming over Server-Sent Events: `POST /v1/chat/stream`.
/// The event contract is documented in backend-exp/README.md.
final class SseTransport implements ChatTransport {
  const SseTransport(this._api, {this.path = 'v1/chat/stream', this.authenticated = false});

  final ApiClient _api;
  final String path;
  final bool authenticated;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) async* {
    final images = imageRefsIn(request.history, pending: request.attachments);
    final outputs = withImageNotes(toolOutputsByMessage(request.history), images);
    final pendingNotes = [
      for (final r in images)
        if (r.messageId == null) r.note,
    ].join('\n');
    final body = <String, Object?>{
      'model': request.model.id.value,
      'mode': request.mode.name,
      'tools_enabled': request.toolsEnabled,
      'session': ?request.conversationId,
      'memory': ?request.memory,
      'skills': ?request.skills,
      'effort': ?request.effort,
      'reply_language': ?request.replyLanguage,
      'force_tool': ?request.forceTool,
      if (request.mode == ChatMode.research) 'research_depth': request.researchDepth.name,
      if (request.clientTools.isNotEmpty) 'client_tools': request.clientTools.toList(growable: false),
      if (request.toolsEnabled && images.isNotEmpty)
        'images': imageRefsJson(images, inMessages: uploadsInMessages(request.history, pending: request.attachments)),
      'messages': [
        for (final m in request.history)
          if (m.status == MessageStatus.complete)
            if ([m.plainText, ?outputs[m.id]].where((t) => t.isNotEmpty).join('\n\n') case final text
                when text.isNotEmpty || m.attachments.isNotEmpty)
              {'role': m.role.name, 'content': messageContent(text, m.attachments)},
        {
          'role': 'user',
          'content': messageContent(
            [request.prompt, pendingNotes].where((t) => t.isNotEmpty).join('\n\n'),
            request.attachments,
          ),
        },
      ],
    };

    await for (final event in _api.postSse(
      path,
      body,
      authenticated: authenticated,
      cancel: cancel,
      headers: request.providerKeys,
    )) {
      final Object? data;
      try {
        data = event.data.isEmpty ? const <String, Object?>{} : jsonDecode(event.data);
      } on FormatException {
        throw ProtocolError('Malformed ${event.event} event.');
      }
      switch ((event.event, data)) {
        case ('route', {'model': final String model}):
          final route = data as Map;
          yield RouteChosen(
            model: ModelId(model),
            mode: ChatMode.values.asNameMap()[route['mode']] ?? request.mode,
            toolsEnabled: route['tools_enabled'] as bool? ?? request.toolsEnabled,
          );
        case ('delta' || 'message', {'text': final String text}):
          yield TextDelta(text);
        case ('reasoning', {'text': final String text}):
          yield ReasoningDelta(text);
        case ('sources', {'sources': final List<Object?> list}):
          yield SourcesFound(list.map(Source.fromJson).nonNulls.toList(growable: false));
        case ('tool', {'id': final String id, 'name': final String name}):
          yield UiToolCall(id: id, name: name, argumentsJson: jsonEncode((data as Map)['arguments'] ?? const {}));
        case ('tool_wait', {'id': final String id, 'name': final String name}):
          yield ToolWait(id: id, name: name, argumentsJson: jsonEncode((data as Map)['arguments'] ?? const {}));
        case ('tool_status', {'id': final String id, 'name': final String name, 'status': final String status}):
          yield ToolProgress(
            id: id,
            name: name,
            status: ToolRunStatus.values.asNameMap()[status] ?? ToolRunStatus.running,
            detail: (data as Map)['detail'] as String?,
          );
        case ('image', {'mime': final String mime, 'data': final String b64}):
          final image = data as Map;
          yield ImageOutput(
            base64Decode(b64),
            mime,
            imageId: image['image_id'] as String?,
            prompt: image['prompt'] as String?,
            revises: image['revises'] as String?,
          );
        case ('usage', final Map<String, Object?> u):
          yield UsageReport(
            promptTokens: (u['prompt_tokens'] as num?)?.toInt() ?? 0,
            completionTokens: (u['completion_tokens'] as num?)?.toInt() ?? 0,
            cachedTokens: (u['cached_tokens'] as num?)?.toInt() ?? 0,
            cacheWriteTokens: (u['cache_write_tokens'] as num?)?.toInt() ?? 0,
            chargedMicros: (u['charged_micros'] as num?)?.toInt() ?? 0,
            ownKeyMicros: (u['byok_cost_micros'] as num?)?.toInt() ?? 0,
            model: u['model'] as String?,
            // Side calls cost money but don't fill the chat's context.
            followUps: const {'followups', 'search', 'research', 'decide', 'summarise'}.contains(u['kind']),
          );
        case ('followups', {'questions': final List<Object?> list}):
          yield FollowUpsSuggested(list.whereType<String>().toList(growable: false));
        case ('done', _):
          yield const TurnDone();
          return;
        case ('error', {'message': final String message}):
          final status = ((data as Map)['status'] as num?)?.toInt();
          final retryable = data['retryable'] == true;
          throw HttpStatusError(status != null && status >= 400 ? status : (retryable ? 503 : 502), message);
        default:
          break; // Unknown events are ignored for forward compatibility.
      }
    }
    throw const ProtocolError('The stream ended before the response finished.');
  }
}

/// Answers client-executed tool calls ([ToolWait]) of a turn in flight.
abstract interface class ToolResults {
  /// Sends [result] (a string, or any JSON) for [callId]; [isError] says the
  /// app could not run the tool and [result] tells why. False when no turn
  /// waits for the call any more (it timed out or finished).
  Future<bool> resolve(String callId, Object? result, {bool isError = false});
}

/// `POST /v1/chat/tool_result {call_id, result, is_error}`.
final class HttpToolResults implements ToolResults {
  const HttpToolResults(this._api, {this.authenticated = false});

  final ApiClient _api;
  final bool authenticated;

  @override
  Future<bool> resolve(String callId, Object? result, {bool isError = false}) async {
    try {
      await _api.postJson('v1/chat/tool_result', {
        'call_id': callId,
        'result': result,
        'is_error': isError,
      }, authenticated: authenticated);
      return true;
    } on HttpStatusError catch (e) {
      if (e.statusCode == 404) return false;
      rethrow;
    }
  }
}

/// What the model made with UI tools in earlier turns, as text per message id,
/// so a later turn can see (and edit) it: each artifact's latest content sits in
/// the message that last changed it, inside `<artifact id kind title>` tags
/// (`edited_by="user"` when the user saved that version by hand in the panel);
/// older versions and other visuals are one-line notes.
Map<String, String> toolOutputsByMessage(List<Message> history) {
  final latest = {for (final a in artifactsIn(history)) a.latest.callId: a};
  final out = <String, String>{};
  for (final m in history) {
    final notes = <String>[];
    for (final call in m.parts.whereType<ToolCallPart>()) {
      if (call.toolName == askUserTool) {
        notes.add(askUserNote(call));
        continue;
      }
      if (call.toolName == 'memory') {
        if (memoryCallNote(call) case final note?) notes.add(note);
        continue;
      }
      if (skillChatTools.contains(call.toolName)) {
        if (skillCallNote(call) case final note?) notes.add(note);
        continue;
      }
      final visual = Visual.fromPart(call);
      if (visual == null) continue;
      if (artifactTools.contains(call.toolName)) {
        final id = visual.str('id').isEmpty ? visual.callId : visual.str('id');
        if (latest[call.callId ?? visual.callId] case final artifact?) {
          final v = artifact.latest;
          final kind = call.toolName == 'create_artifact' ? visual.str('kind') : artifact.versions.first.str('kind');
          // Drawings saved from the editor are full scenes: send the model a slim copy.
          final content = kind == 'drawing' ? drawingForPrompt(v.str('content')) : v.str('content');
          notes.add(
            '<artifact id="$id" kind="${kind.isEmpty ? 'markdown' : kind}" title="${artifact.title}"'
            '${v.editedByUser ? ' edited_by="user"' : ''}>\n'
            '$content\n</artifact>',
          );
        } else {
          notes.add('[${call.toolName} $id: an earlier version, superseded below]');
        }
      } else {
        notes.add('[Showed the user ${visual.kind.label.toLowerCase()}: ${visual.title}]');
      }
    }
    if (notes.isNotEmpty) out[m.id] = notes.join('\n\n');
  }
  return out;
}

/// A message's `content`: the text alone, or (with attachments) OpenAI content
/// parts, files first and the typed text last. Text files are inlined; files
/// whose bytes are gone are skipped.
Object messageContent(String text, List<AttachmentPart> attachments) {
  if (attachments.isEmpty) return text;
  return [
    for (final a in attachments)
      if (a.bytes case final bytes?)
        switch (a.kind) {
          AttachmentKind.image => {
            'type': 'image_url',
            'image_url': {'url': 'data:${a.mimeType};base64,${base64Encode(bytes)}'},
          },
          AttachmentKind.pdf => {
            'type': 'file',
            'file': {'filename': a.name, 'file_data': 'data:application/pdf;base64,${base64Encode(bytes)}'},
          },
          AttachmentKind.audio => {
            'type': 'input_audio',
            'input_audio': {'data': base64Encode(bytes), 'format': a.mimeType.contains('wav') ? 'wav' : 'mp3'},
          },
          AttachmentKind.text || AttachmentKind.other => {
            'type': 'text',
            'text': '<file name="${a.name}">\n${utf8.decode(bytes, allowMalformed: true)}\n</file>',
          },
        },
    if (text.isNotEmpty) {'type': 'text', 'text': text},
  ];
}

/// Picks the transport per model: image-output models go to `/v1/images`,
/// everything else streams.
final class TransportRouter implements ChatTransport {
  const TransportRouter({required this.stream, required this.image});

  final ChatTransport stream;
  final ChatTransport image;

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) =>
      (request.model.output == Modality.image ? image : stream).send(request, cancel: cancel);
}

/// "[Saved to memory (user): …]" for a memory edit in an earlier turn, so
/// the model knows it happened (the chat's memory block stays frozen).
String? memoryCallNote(ToolCallPart call) {
  final Map<String, Object?> args;
  try {
    args = switch (jsonDecode(call.argumentsJson)) {
      final Map<String, Object?> m => m,
      _ => const {},
    };
  } on FormatException {
    return null;
  }
  if (call.resultJson case final String r when r.contains('"error":true')) return null;
  final target = args['target'] ?? 'user';
  return switch (args['action']) {
    'add' => '[Saved to memory ($target): ${args['text']}]',
    'replace' => '[Changed memory ($target): ${args['text']}]',
    'remove' => '[Removed from memory ($target): ${args['old_text']}]',
    _ => null,
  };
}
