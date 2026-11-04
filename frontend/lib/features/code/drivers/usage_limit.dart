// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../harness/events.dart';

/// The `code` of a `ConversationErrorEvent` that says the lead ran out: its
/// plan's usage limit, its key's credits or quota. The controller offers to
/// continue on another harness (Stage 3); drivers classify their own errors
/// with [usageLimitEvent].
const usageLimitCode = 'usage_limit';

/// A lead that stopped because its plan or key ran out.
@immutable
final class UsageLimit {
  const UsageLimit({required this.message, this.resetsAt});

  /// The harness's own words, shown as is.
  final String message;

  /// When the limit lifts, if the harness said.
  final DateTime? resetsAt;
}

/// The event a driver emits when its CLI reports a usage limit: a
/// [ConversationFailure] with [usageLimitCode], so code that doesn't know
/// about limits still shows the message.
ConversationFailure usageLimitEvent(String id, String message, {DateTime? resetsAt}) => HarnessEvent.decode({
  'kind': 'ConversationErrorEvent',
  'id': id,
  'code': usageLimitCode,
  'detail': message,
  if (resetsAt != null) 'resets_at': resetsAt.toUtc().toIso8601String(),
}) as ConversationFailure;

/// The limit [event] reports, or null when it isn't one.
UsageLimit? usageLimitOf(HarnessEvent event) {
  if (event is! ConversationFailure || event.raw['code'] != usageLimitCode) return null;
  final at = event.raw['resets_at'];
  return UsageLimit(message: event.message, resetsAt: at is String ? DateTime.tryParse(at) : null);
}
