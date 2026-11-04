import '../harness/events.dart';

/// Conversation rewind on the agent-server's event tree (OpenHands 1.59).
///
/// Every stored event carries a `parent_id`; the conversation's HEAD
/// (`leaf_event_id`) is the parent of the next one. `POST …/navigate
/// {event_id}` moves HEAD back to an earlier event: the agent's context
/// becomes the path from the root to it, the abandoned branch stays on disk,
/// and the next message starts a new branch there. Nothing tells listeners
/// HEAD moved, and `events/search` and the socket's `resend_mode=all` return
/// every branch, so the client keeps to the active one itself
/// ([activeBranch]). Checked against agent-server 1.59.0 (create, three
/// messages with `run: false`, navigate, a fourth message).

/// State updates and conversation errors hang off HEAD without becoming it
/// (the server's "non-tree artifacts").
bool isBranchArtifact(HarnessEvent e) =>
    e.raw['kind'] == 'ConversationStateUpdateEvent' || e.raw['kind'] == 'ConversationErrorEvent';

String? _rawParent(HarnessEvent e) => e.raw['parent_id'] as String?;

/// Each tree event's parent id (null for a root), indexed like [events].
/// Events stored before the tree existed have no `parent_id` and chain to
/// the previous tree event, as on the server; a parent the log doesn't hold
/// (the server's root marker) makes a root.
List<String?> _parents(List<HarnessEvent> events) {
  final ids = {for (final e in events) e.id};
  final out = <String?>[];
  String? previous;
  for (final e in events) {
    final raw = _rawParent(e);
    out.add(raw == null ? previous : (ids.contains(raw) ? raw : null));
    if (!isBranchArtifact(e)) previous = e.id;
  }
  return out;
}

/// The events of [events] on the branch that ends at [leaf], in their
/// original order: the tree events from the root to [leaf], and the state
/// updates and errors attached to them. Events after [leaf] on the same
/// branch are dropped too, as after a rewind. [events] comes back as it is
/// when it doesn't hold [leaf] (nothing to go on).
List<HarnessEvent> activeBranch(List<HarnessEvent> events, String leaf) {
  final at = events.indexWhere((e) => e.id == leaf);
  if (at < 0) return events;
  final parents = _parents(events);
  final index = {for (var i = 0; i < events.length; i++) events[i].id: i};
  final path = <String>{};
  for (int? i = at; i != null;) {
    if (!path.add(events[i].id)) break; // a cycle would be a corrupt log
    final p = parents[i];
    i = p == null ? null : index[p];
  }
  return [
    for (final e in events)
      if (isBranchArtifact(e) ? _artifactOn(e, path, index) : path.contains(e.id)) e,
  ];
}

bool _artifactOn(HarnessEvent e, Set<String> path, Map<String, int> index) {
  final p = _rawParent(e);
  // Unparented (older servers) or parented to the root marker: keep.
  return p == null || !index.containsKey(p) || path.contains(p);
}

/// The ids in [events] that are off the branch ending at [leaf] (events the
/// socket replays from abandoned branches). Empty without a [leaf].
Set<String> offBranch(List<HarnessEvent> events, String? leaf) {
  if (leaf == null) return const {};
  final kept = {for (final e in activeBranch(events, leaf)) e.id};
  return {
    for (final e in events)
      if (!kept.contains(e.id)) e.id,
  };
}

/// Where HEAD goes to forget the user message [messageId] and everything
/// after it: the message's parent. Null is the empty tree (the message was
/// the first event). Throws [ArgumentError] when [events] doesn't hold it.
String? rewindHead(List<HarnessEvent> events, String messageId) {
  final i = events.indexWhere((e) => e.id == messageId);
  if (i < 0) throw ArgumentError.value(messageId, 'messageId', 'not in this conversation');
  return _parents(events)[i];
}

/// [events] after HEAD moved to [head] (null: the empty tree).
List<HarnessEvent> rewound(List<HarnessEvent> events, String? head) => head == null ? [] : activeBranch(events, head);

/// What `/rewind` and "Rewind to here" did.
final class RewindOutcome {
  const RewindOutcome({required this.kind, this.conversation = false, this.files = false, this.message = ''});

  const RewindOutcome.busy() : this(kind: RewindKind.busy);
  const RewindOutcome.nothing() : this(kind: RewindKind.nothing);
  const RewindOutcome.failed(String message) : this(kind: RewindKind.failed, message: message);

  final RewindKind kind;

  /// The agent forgot the later turns.
  final bool conversation;

  /// The files went back to the checkpoint.
  final bool files;

  /// Why something was skipped or failed.
  final String message;

  /// A one-line summary for a toast.
  String get label => switch (kind) {
    RewindKind.busy => 'The agent is still working; stop it and try again.',
    RewindKind.nothing => 'Nothing to rewind yet.',
    RewindKind.failed => "Couldn't rewind: $message",
    RewindKind.done => switch ((conversation, files)) {
      (true, true) => 'Rewound the conversation and the files.',
      (true, false) => message.isEmpty ? 'Rewound the conversation.' : 'Rewound the conversation. $message',
      (false, true) => message.isEmpty ? 'Restored the files.' : 'Restored the files. $message',
      (false, false) => message.isEmpty ? 'Nothing changed.' : message,
    },
  };
}

enum RewindKind { done, busy, nothing, failed }

/// The confirmation text for rewinding to before [what] ("this message",
/// "your last 2 messages"); [files] when the session has checkpoints, and
/// [conversation] when the harness can go back too (else it keeps the turns).
String rewindPrompt(String what, {required bool files, bool conversation = true}) => files && !conversation
    ? "Puts this session's files back to how they were before $what. "
          'The agent keeps the conversation and is told the files went back.'
    : files
    ? "Takes the conversation and this session's files back to before $what. "
          'The agent forgets $what and everything it did after.'
    : 'Takes the conversation back to before $what: the agent forgets it and everything it did after. '
          'The files stay as they are.';

/// Goes before the next message after the files were rewound but the
/// harness kept the conversation: [userText] is the turn the files went
/// back to the start of.
String rewindNote(String userText) {
  final line = userText.trim().replaceAll(RegExp(r'\s+'), ' ');
  final quoted = line.length > 80 ? '${line.substring(0, 80)}…' : line;
  return '<everyai-rewind>The user put the project\'s files back to how they were before their message "$quoted". '
      'Every file change made after that point is undone, even though this conversation still shows it. '
      'Read files again before relying on what you remember of them.</everyai-rewind>';
}
