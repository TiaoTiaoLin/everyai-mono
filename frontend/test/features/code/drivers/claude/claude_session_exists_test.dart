import 'dart:io';

import 'package:every_ai/features/code/drivers/claude/claude_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('claude_cfg'));
  tearDown(() => root.deleteSync(recursive: true));

  test('finds the session in any project folder, so a symlinked or shortened path still matches', () async {
    File('${root.path}/projects/-private-tmp-x/abc.jsonl').createSync(recursive: true);
    expect(await claudeSessionExists('/tmp/x', 'abc', configDir: root.path), isTrue);
  });

  test('a store without the session says it is gone', () async {
    Directory('${root.path}/projects/-tmp-x').createSync(recursive: true);
    expect(await claudeSessionExists('/tmp/x', 'abc', configDir: root.path), isFalse);
  });

  test('no projects folder means it cannot tell, so the resume is tried', () async {
    expect(await claudeSessionExists('/tmp/x', 'abc', configDir: root.path), isTrue);
  });
}
