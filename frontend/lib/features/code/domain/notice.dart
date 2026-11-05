import 'dart:math';

/// What EveryAI sends an outside lead (Claude Code, Codex, ...) for a fork's report or question and a workflow's
/// result. Those leads read it as a user message, so the notice is wrapped in a tag carrying the session's nonce,
/// which the briefing names: a line in a file or web page, or in another fork's report, can't pass for one. This is
/// to avoid confusion, not a security boundary (the nonce sits in the lead's system prompt).
const noticeTag = 'everyai-notice';

/// A fresh nonce for one session (16 random bytes, hex).
String newNoticeNonce() {
  final random = Random.secure();
  return [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

String _word(String s) => s.replaceAll(RegExp(r'[^\w-]'), '');

/// Defuses a notice or task-notification tag in [text], so a report can't close the wrapper or open a forged one.
String defuseNoticeTags(String text) => text
    .replaceAll(RegExp('</?$noticeTag', caseSensitive: false), '‹$noticeTag')
    .replaceAll(RegExp('</?task-notification', caseSensitive: false), '‹task-notification');

/// [body] as a notice of [kind] (`fork-report`, `fork-question`, `workflow-result`) about [id]. The body's own
/// `<task-notification>` or `<workflow-result>` stays as it is; only a forged wrapper tag inside it is defused.
String wrapNotice({required String kind, required String id, required String nonce, required String body}) =>
    '<$noticeTag kind="${_word(kind)}" id="${_word(id)}" nonce="${_word(nonce)}">\n'
    '${body.replaceAll(RegExp('</?$noticeTag', caseSensitive: false), '‹$noticeTag')}\n'
    '</$noticeTag>';

final _wrapped = RegExp('^<$noticeTag [^>\\n]*>\\n([\\s\\S]*)\\n</$noticeTag>\$');

/// The body of a wrapped notice, or [text] as it is.
String unwrapNotice(String text) => _wrapped.firstMatch(text)?.group(1) ?? text;
