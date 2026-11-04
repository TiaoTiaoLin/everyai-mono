// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../../core/config/version.dart';
import 'host.dart' show HostResult;

// The report_issue host tool: it only builds a prefilled GitHub link for an EveryAI problem the user agreed to
// report. No network, no cost; the user opens the link and decides there.

const reportIssueTool = 'report_issue';

const reportIssueSpec = <String, Object?>{
  'name': reportIssueTool,
  'description':
      'Builds a link that opens a prefilled GitHub issue about an EveryAI problem. Use it only after the user said '
      'yes to reporting, and only when `gh` is not signed in. Give the user the draft and the link; do not open it. '
      'Leave out code, file paths, secrets and anything from their project.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'title': {'type': 'string', 'description': 'One line'},
      'tool': {'type': 'string', 'description': 'The EveryAI tool, skill or workflow concerned'},
      'expected': {'type': 'string', 'description': 'What you expected'},
      'happened': {'type': 'string', 'description': 'What happened instead'},
    },
    'required': ['title', 'tool', 'happened'],
    'additionalProperties': false,
  },
  'annotations': {'readOnlyHint': true},
};

const _maxTitle = 120;
const _maxUrl = 7500;

// POSIX absolute (two or more segments), ~/..., and Windows drive paths.
final _path = RegExp(r'(?:~|(?<![\w.:/-])/(?=[\w.-]+/))[/\w.\-@+]*[\w.\-]|[A-Za-z]:\\[^\s"\x27`]+');

String _clean(String s) => s.replaceAll(_path, '<path>').trim();

String _cut(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

/// The prefilled new-issue link: title, body (tool, expected, what happened, then harness, model and version) and
/// the `feedback` label. Paths are replaced, the title is capped and the whole link stays under GitHub's limit.
Uri reportIssueUri({
  required String title,
  required String tool,
  String expected = '',
  required String happened,
  required String harness,
  required String model,
}) {
  final t = _cut(_clean(title).replaceAll(RegExp(r'\s+'), ' '), _maxTitle);
  final fields = [_clean(tool), _clean(expected), _clean(happened)];
  Uri build() => Uri.parse(issuesUrl).replace(
    queryParameters: {
      'title': t,
      'body': [
        '**Tool:** ${fields[0]}',
        if (fields[1].isNotEmpty) '**Expected:** ${fields[1]}',
        '**What happened:** ${fields[2]}',
        '',
        '---',
        'Harness: $harness · Model: $model · App: $appVersion',
      ].join('\n'),
      'labels': 'feedback',
    },
  );
  var uri = build();
  // Shrink the longest field until the encoded link fits.
  while (uri.toString().length > _maxUrl) {
    var longest = 0;
    for (var i = 1; i < fields.length; i++) {
      if (fields[i].length > fields[longest].length) longest = i;
    }
    if (fields[longest].length < 40) break;
    final f = fields[longest].replaceAll('…', '');
    fields[longest] = '${f.substring(0, (f.length * 0.8).floor())}…';
    uri = build();
  }
  return uri;
}

/// The tool's result: the link, or an error naming the missing argument.
HostResult hostReportIssue(Map<String, Object?> args, {required String harness, required String model}) {
  String arg(String k) => (args[k] as String?)?.trim() ?? '';
  for (final k in const ['title', 'tool', 'happened']) {
    if (arg(k).isEmpty) return (text: 'Error: report_issue needs "$k".', isError: true);
  }
  final uri = reportIssueUri(
    title: arg('title'),
    tool: arg('tool'),
    expected: arg('expected'),
    happened: arg('happened'),
    harness: harness,
    model: model,
  );
  return (
    text:
        'Show the user the draft and this link, and let them open it; do not open it yourself. They send the '
        'report from the page.\n$uri',
    isError: false,
  );
}
