import 'package:every_ai/core/config/version.dart';
import 'package:every_ai/features/code/harness/everyai/prompt_io.dart';
import 'package:every_ai/features/code/host/host_report.dart';
import 'package:flutter_test/flutter_test.dart';

Uri _link({
  String title = 'check hangs',
  String tool = 'check',
  String expected = 'a result',
  String happened = 'it hung',
}) => reportIssueUri(
  title: title,
  tool: tool,
  expected: expected,
  happened: happened,
  harness: 'Claude Code',
  model: 'sonnet',
);

void main() {
  test('the link carries title, body, harness, model, version and the feedback label', () {
    final u = _link();
    expect(u.toString(), startsWith(issuesUrl));
    expect(u.queryParameters['title'], 'check hangs');
    expect(u.queryParameters['labels'], 'feedback');
    final body = u.queryParameters['body']!;
    expect(body, contains('**Tool:** check'));
    expect(body, contains('**Expected:** a result'));
    expect(body, contains('**What happened:** it hung'));
    expect(body, contains('Harness: Claude Code · Model: sonnet · App: $appVersion'));
  });

  test('special characters round-trip through the encoding', () {
    const happened = 'a&b=c #1\nline two 😀 100%';
    final u = _link(happened: happened);
    expect(u.toString(), isNot(contains('\n')));
    expect(u.toString(), isNot(contains('#1')));
    expect(u.queryParameters['body'], contains(happened));
  });

  test('absolute paths are replaced, POSIX and Windows', () {
    final u = _link(happened: 'failed in /Users/ann/proj/lib/a.dart and C:\\Users\\ann\\proj\\a.dart, ~/work/x.txt');
    final body = u.queryParameters['body']!;
    expect(body, isNot(contains('ann')));
    expect(body, isNot(contains('a.dart')));
    expect(body, contains('<path>'));
  });

  test('the title is capped and an oversized body is cut under the link limit', () {
    final u = _link(title: 'x' * 500, happened: 'word ' * 5000, expected: 'é' * 3000);
    expect(u.queryParameters['title']!.length, lessThanOrEqualTo(121));
    expect(u.toString().length, lessThanOrEqualTo(7500));
    expect(u.queryParameters['body'], contains('…'));
  });

  test('the tool returns the link, or names the missing argument', () {
    final ok = hostReportIssue({'title': 'T', 'tool': 'check', 'happened': 'h'}, harness: 'EveryAI', model: 'm');
    expect(ok.isError, isFalse);
    expect(ok.text, contains('$issuesUrl?'));
    final bad = hostReportIssue({'title': 'T', 'tool': 'check'}, harness: 'EveryAI', model: 'm');
    expect(bad.isError, isTrue);
    expect(bad.text, contains('"happened"'));
    expect(reportIssueSpec['annotations'], {'readOnlyHint': true});
  });

  test("the EveryAI harness's own rules carry both notes", () {
    expect(harnessRules, contains('use it before a method of your own'));
    expect(harnessRules, contains('only after the user says yes'));
    expect(harnessRules, contains('never again after a no'));
    expect(harnessRules, contains('gh issue create -R'));
  });
}
