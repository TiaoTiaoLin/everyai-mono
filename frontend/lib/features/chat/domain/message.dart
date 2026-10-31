import 'package:flutter/foundation.dart';

import '../../attachments/attachment.dart';
import '../../models/domain/model_catalog.dart';
import '../../usage/usage_totals.dart';

enum Role { user, assistant, system }

/// How the assistant should answer: each mode is a set of instructions on the
/// backend (`backend-exp/src/modes.zig`).
enum ChatMode {
  chat('Chat', 'Answer from the model alone'),
  search('Search', 'Search the web and cite sources'),
  research('Research', 'Researchers gather sources; you get a cited report'),
  learn('Learn', 'Step-by-step teaching with visuals and quizzes'),
  summarise('Summarise', 'Condense a file, page or chat');

  const ChatMode(this.label, this.description);
  final String label;
  final String description;
}

/// How far Research goes: researchers per round, rounds, the models they
/// may use and what they may spend (caps in `backend-exp/src/research.zig`).
enum ResearchDepth {
  quick('Quick', 'Two researchers, one round'),
  standard('Standard', 'Up to four researchers, two rounds'),
  deep('Deep', 'Up to six researchers on stronger models, three rounds');

  const ResearchDepth(this.label, this.description);
  final String label;
  final String description;
}

enum MessageStatus {
  /// Assistant message still receiving tokens.
  streaming,
  complete,
  failed,
  cancelled,
}

/// One piece of a message. Sealed, so renderers must handle every kind.
sealed class MessagePart {
  const MessagePart();
}

final class TextPart extends MessagePart {
  const TextPart(this.text);
  final String text;
}

/// Image bytes held in memory, or a reference to a blob in the store. A
/// generated image has an [imageId] (`img_<n>`, stable in its conversation),
/// the [prompt] that made it, and [revises]: the image it is a new version of.
final class ImagePart extends MessagePart {
  const ImagePart({this.bytes, this.blobRef, this.mimeType = 'image/webp', this.imageId, this.prompt, this.revises})
    : assert(bytes != null || blobRef != null);
  final Uint8List? bytes;
  final String? blobRef;
  final String mimeType;
  final String? imageId;
  final String? prompt;
  final String? revises;

  bool get isSvg => mimeType == 'image/svg+xml';
}

/// A web source the answer drew on (search modes). Cited in text as `[n]`.
@immutable
final class Source {
  const Source({required this.url, required this.title, this.snippet});

  final Uri url;
  final String title;
  final String? snippet;

  /// `en.wikipedia.org` → `wikipedia.org`
  String get site => url.host.replaceFirst(RegExp(r'^(www|en|m)\.'), '');

  Map<String, Object?> toJson() => {'url': '$url', 'title': title, 'snippet': snippet};

  static Source? fromJson(Object? json) => switch (json) {
    {'url': final String url, 'title': final String title} => Source(
      url: Uri.parse(url),
      title: title,
      snippet: json['snippet'] as String?,
    ),
    _ => null,
  };
}

/// Sources shown above an answer, in citation order (`[1]` is `sources[0]`).
final class SourcesPart extends MessagePart {
  const SourcesPart(this.sources);
  final List<Source> sources;
}

/// Suggested next questions shown under an answer.
final class FollowUpsPart extends MessagePart {
  const FollowUpsPart(this.questions);
  final List<String> questions;
}

/// The model's thinking before (or between) its answer, shown collapsed.
final class ReasoningPart extends MessagePart {
  const ReasoningPart(this.text);
  final String text;
}

/// A tool call the app renders by [toolName] (quiz, chart, artifact, …), in
/// its place among the message's text.
final class ToolCallPart extends MessagePart {
  const ToolCallPart({required this.toolName, required this.argumentsJson, this.resultJson, this.callId});
  final String toolName;
  final String argumentsJson;
  final String? resultJson;
  final String? callId;
}

final class ArtifactPart extends MessagePart {
  const ArtifactPart({required this.artifactId, required this.title, required this.kind});
  final String artifactId;
  final String title;
  final String kind;
}

/// A file the user attached: bytes in memory, or a blob reference once
/// stored. Sent to the model with its message.
final class AttachmentPart extends MessagePart {
  const AttachmentPart({
    required this.name,
    required this.mimeType,
    required this.kind,
    required this.size,
    this.bytes,
    this.blobRef,
  });

  factory AttachmentPart.of(Attachment a) =>
      AttachmentPart(name: a.name, mimeType: a.mime, kind: a.kind, size: a.size, bytes: a.bytes);

  final String name;
  final String mimeType;
  final AttachmentKind kind;
  final int size;
  final Uint8List? bytes;
  final String? blobRef;
}

/// Tokens and charge for the turn that produced this message (not rendered;
/// summed for the composer's meter).
final class UsagePart extends MessagePart {
  const UsagePart(this.totals);
  final UsageTotals totals;
}

/// What EveryAI · Auto picked for this answer (the `route` event): the
/// model that wrote it, the mode and whether rich answers were on. Shown as
/// a chip on the reply.
final class RoutePart extends MessagePart {
  const RoutePart({required this.model, required this.mode, this.toolsEnabled = true});
  final ModelId model;
  final ChatMode mode;
  final bool toolsEnabled;

  Map<String, Object?> toJson() => {'model': model.value, 'mode': mode.name, 'tools_enabled': toolsEnabled};

  static RoutePart? fromJson(Object? json) => switch (json) {
    {'model': final String model} => RoutePart(
      model: ModelId(model),
      mode: ChatMode.values.asNameMap()[json['mode']] ?? ChatMode.chat,
      toolsEnabled: json['tools_enabled'] != false,
    ),
    _ => null,
  };
}

@immutable
final class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.parts,
    required this.createdAt,
    this.model,
    this.status = MessageStatus.complete,
    this.error,
  });

  final String id;
  final String conversationId;
  final Role role;
  final List<MessagePart> parts;
  final DateTime createdAt;

  /// The model that actually produced this message (null for user messages).
  final ModelId? model;
  final MessageStatus status;
  final String? error;

  bool get isUser => role == Role.user;

  UsageTotals get usage => parts.whereType<UsagePart>().fold(UsageTotals.zero, (sum, p) => sum + p.totals);

  /// What Auto picked for this answer, or null (another model answered).
  RoutePart? get route => parts.whereType<RoutePart>().firstOrNull;

  List<AttachmentPart> get attachments => parts.whereType<AttachmentPart>().toList(growable: false);

  List<Source> get sources => parts.whereType<SourcesPart>().expand((p) => p.sources).toList(growable: false);

  /// All text parts joined, for copy, search and titles.
  String get plainText => parts.whereType<TextPart>().map((p) => p.text).join('\n\n');

  Message copyWith({List<MessagePart>? parts, MessageStatus? status, String? error}) => Message(
    id: id,
    conversationId: conversationId,
    role: role,
    parts: parts ?? this.parts,
    createdAt: createdAt,
    model: model,
    status: status ?? this.status,
    error: error ?? this.error,
  );
}

@immutable
final class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.model,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
  });

  final String id;
  final String title;
  final ModelId model;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;
}
