import '../git/git_models.dart';
import 'review.dart';

/// The model's messages for a commit message: the session's [title], what
/// the user added ([hint]) and the uncommitted [files].
List<Map<String, Object?>> commitMessageRequest({
  required List<FileDiff> files,
  String title = '',
  String hint = '',
  String style = '',
}) {
  final diff = renderDiff(files, maxChars: 24000);
  return [
    {'role': 'system', 'content': _commitSystem},
    {
      'role': 'user',
      'content': [
        if (title.trim().isNotEmpty) 'The session was about: ${title.trim()}',
        if (hint.trim().isNotEmpty) 'The developer adds: ${hint.trim()}',
        if (style.trim().isNotEmpty) "The project's commit style:\n${style.trim()}",
        'Changes (${diffStat(files)}):\n```diff\n${diff.text}```${diff.cut ? '\n(The diff is cut short.)' : ''}',
      ].join('\n\n'),
    },
  ];
}

/// Written for this app.
const _commitSystem = '''
You write git commit messages. Reply with only the message, no code fence and no commentary.

- First line: what the commit does, in the imperative ("Add …", "Fix …"), at most 72 characters, no trailing period.
- Then, if the change is not obvious from that line, a blank line and a short body (wrapped at 72 columns) on what changed and why. Skip the body for small changes.
- Describe the change itself; don't mention tools, assistants or who wrote it, and add no trailers.
- Follow the project's commit style when one is given.''';

/// [reply] as a commit message: no fence, no quotes around it, no AI-credit
/// lines, no trailing blank lines. Empty when nothing is left.
String cleanCommitMessage(String reply) {
  var t = reply.trim();
  final fence = RegExp(r'^```[\w-]*\n([\s\S]*?)\n?```$').firstMatch(t);
  if (fence != null) t = fence[1]!.trim();
  if (t.length > 1 && (t.startsWith('"') && t.endsWith('"') || t.startsWith("'") && t.endsWith("'"))) {
    t = t.substring(1, t.length - 1).trim();
  }
  t = t.replaceFirst(RegExp(r'^(commit message|message)\s*:\s*', caseSensitive: false), '');
  return stripBranding(t).trim();
}

/// The model's messages for a pull request: the commits on the branch and its diff.
List<Map<String, Object?>> prRequest({
  required List<FileDiff> files,
  required List<String> commits,
  String title = '',
  String hint = '',
}) {
  final diff = renderDiff(files, maxChars: 24000);
  return [
    {'role': 'system', 'content': _prSystem},
    {
      'role': 'user',
      'content': [
        if (title.trim().isNotEmpty) 'The session was about: ${title.trim()}',
        if (hint.trim().isNotEmpty) 'The developer adds: ${hint.trim()}',
        if (commits.isNotEmpty) 'Commits on the branch:\n${[for (final c in commits) '- $c'].join('\n')}',
        'Changes against the base branch (${diffStat(files)}):\n```diff\n${diff.text}```'
            '${diff.cut ? '\n(The diff is cut short.)' : ''}',
      ].join('\n\n'),
    },
  ];
}

/// Written for this app.
const _prSystem = '''
You write pull request descriptions. Reply with only this shape, no code fence:

Title: <what the change does, imperative, at most 70 characters>

<the body in Markdown: a short summary paragraph, then a "Changes" list of the notable changes, then a "Testing" line on how it was checked, if the record shows it>

Describe the change itself; don't mention tools, assistants or who wrote it.''';

/// The title and body from [reply]; [fallbackTitle] when it has no title.
({String title, String body}) parsePrDraft(String reply, {String fallbackTitle = ''}) {
  var t = reply.trim();
  final fence = RegExp(r'^```[\w-]*\n([\s\S]*?)\n?```$').firstMatch(t);
  if (fence != null) t = fence[1]!.trim();
  final lines = t.split('\n');
  var title = '';
  var rest = lines;
  final i = lines.indexWhere((l) => l.trim().isNotEmpty);
  if (i >= 0) {
    final first = lines[i].trim();
    final m = RegExp(r'^(?:#+\s*)?(?:\*\*)?title(?:\*\*)?\s*:\s*(.*)$', caseSensitive: false).firstMatch(first);
    title = (m?[1] ?? first.replaceFirst(RegExp(r'^#+\s*'), '')).trim();
    rest = lines.sublist(i + 1);
  }
  if (title.isEmpty) title = fallbackTitle;
  return (title: title, body: stripBranding(rest.join('\n').trim()).trim());
}

/// A pull request body written without a model: the commit subjects
/// (newest first, as `git log` lists them) as a list; '' when there are none.
String plainPrBody(List<String> commits) => [for (final c in commits) '- $c'].join('\n');

/// The GitHub page that opens a pull request from [branch] into [base], when
/// [remoteUrl] is a GitHub remote (https or ssh); null otherwise.
String? githubCompareUrl(String remoteUrl, {required String base, required String branch}) {
  final m = RegExp(r'github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$').firstMatch(remoteUrl.trim());
  if (m == null) return null;
  return 'https://github.com/${m[1]}/${m[2]}/compare/$base...$branch?expand=1';
}

/// How to open the pull request by hand when the GitHub CLI isn't there.
String prInstructions({required String branch, required String base, String remoteUrl = ''}) {
  final compare = githubCompareUrl(remoteUrl, base: base, branch: branch);
  return [
    'The GitHub CLI (`gh`) is not installed or not signed in, so the pull request has to be opened by hand:',
    '',
    '1. Commit the changes (`/commit`), then push the branch:',
    '   `git push -u origin $branch`',
    if (compare != null)
      '2. Open [the compare page]($compare) and create the pull request into `$base`.'
    else
      '2. Open your Git host and create a pull request from `$branch` into `$base`.',
    '',
    'To let EveryAI open it next time: install the GitHub CLI (`brew install gh` on macOS) and run `gh auth login`.',
  ].join('\n');
}
