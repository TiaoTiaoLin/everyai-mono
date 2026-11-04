import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/handoff/native/claude_import.dart';
import 'package:every_ai/features/code/handoff/native/import_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_source.dart';

/// A CLI that takes what it is sent and says nothing.
final class _Quiet implements LineChannel {
  final sent = <String>[];
  final _lines = StreamController<String>();
  @override
  Stream<String> get lines => _lines.stream;
  @override
  String get lastError => '';
  @override
  void send(String line) => sent.add(line);
  @override
  Future<void> close() => _lines.close();
}

List<Map<String, Object?>> _records(String text) => [
  for (final l in const LineSplitter().convert(text))
    if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, Object?>,
];

/// The content blocks of a record's message (a plain string is one text block).
List<Map<String, Object?>> _blocks(Map<String, Object?> r) => switch ((r['message']! as Map)['content']) {
  final String s => [
    {'type': 'text', 'text': s},
  ],
  final List<Object?> l => l.cast<Map<String, Object?>>(),
  _ => const [],
};

void main() {
  late Directory tmp;
  late String work;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('claude_import_test');
    work = '${tmp.resolveSymbolicLinksSync()}/repo';
    Directory(work).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('records match the shape Claude resumed in the spike: a parentUuid chain, a result per call', () {
    final steps = importSteps(source(), into: 'Claude Code')!;
    final lines = claudeSessionLines(steps, sessionId: 'sid', cwd: cwd, start: DateTime.utc(2026, 11, 4));
    final ours = [for (final l in lines) jsonDecode(l) as Map<String, Object?>];
    final spike = _records(File('test/fixtures/drivers/native/claude_written.jsonl').readAsStringSync());
    for (final r in ours) {
      expect(r.keys.toSet(), spike.first.keys.toSet());
      expect((r['isSidechain'], r['userType'], r['cwd'], r['sessionId']), (false, 'external', cwd, 'sid'));
    }
    expect(ours.first['parentUuid'], isNull);
    for (var i = 1; i < ours.length; i++) {
      expect(ours[i]['parentUuid'], ours[i - 1]['uuid']);
      expect(ours[i]['type'], isNot(ours[i - 1]['type']), reason: 'roles alternate');
    }
    final assistants = [
      for (final r in ours)
        if (r['type'] == 'assistant') r['message']! as Map<String, Object?>,
    ];
    final spikeAssistant = spike[1]['message']! as Map<String, Object?>;
    for (final a in assistants) {
      expect(a.keys.toSet(), spikeAssistant.keys.toSet());
      expect(a['model'], '<synthetic>');
    }
    final uses = [
      for (final r in ours)
        for (final b in _blocks(r))
          if (b['type'] == 'tool_use') b,
    ];
    final spikeUses = [
      for (final r in spike)
        for (final b in _blocks(r))
          if (b['type'] == 'tool_use') b,
    ];
    // The same calls the spike wrote (it gave Bash a description too).
    expect(
      [for (final u in uses.take(2)) (u['name'], jsonEncode(u['input']))],
      [
        for (final u in spikeUses) (u['name'], jsonEncode({...(u['input']! as Map)}..remove('description'))),
      ],
    );
    expect(uses.last['input'], {'command': 'git add -A && git commit -m "Add files"'});
    final results = [
      for (final r in ours)
        for (final b in _blocks(r))
          if (b['type'] == 'tool_result') b,
    ];
    expect(results.map((r) => r['tool_use_id']), uses.map((u) => u['id']));
    expect(results.last, {
      'type': 'tool_result',
      'tool_use_id': uses.last['id'],
      'content': notFinishedResult,
      'is_error': true,
    });
    // The facts close the file, in the message with the last results; no reply after the cut.
    expect(ours.last['type'], 'user');
    expect(_blocks(ours.last).last['text'], contains('<cut-turn>'));
  });

  test('writes under the config folder by the real path, adopts it, and the first message resumes it', () async {
    final link = '${tmp.path}/link';
    Link(link).createSync(work);
    final config = '${tmp.path}/claude-config';
    final data = '${tmp.path}/data';
    final quiet = _Quiet();
    final spawned = <List<String>>[];
    final driver = ClaudeDriver(
      dataDir: () async => data,
      spawn: (args, {required cwd, required env, required sessionTag, required logPath}) async {
        spawned.add(args);
        return quiet;
      },
    );
    final env = {'CLAUDE_CONFIG_DIR': config, 'HOME': '${tmp.path}/home'};
    final imported = await ClaudeImporter(
      driver: driver,
      env: (name) async => env[name],
    ).write(source(to: 'claude-code', dir: link));
    expect(imported, isNotNull);
    final id = imported!.nativeId;
    expect(imported.note, 'Imported 2 turns into Claude Code');
    final file = File('$config/projects/${claudeProjectSlug(work)}/$id.jsonl');
    expect(file.existsSync(), isTrue, reason: 'slug of the real path ${claudeProjectSlug(work)}');
    expect(claudeProjectSlug('/private/tmp/a_b.c'), '-private-tmp-a-b-c');
    final records = _records(file.readAsStringSync());
    expect(records.map((r) => r['sessionId']).toSet(), {id});
    expect(records.first['cwd'], work);

    final session = await driver.attach(id);
    await session.send('Finish it.');
    expect(spawned, hasLength(1));
    final at = spawned.single.indexOf('--resume');
    expect(spawned.single[at + 1], id);
    expect(spawned.single, isNot(contains('--session-id')));
    await session.close();
  });

  test(
    'without CLAUDE_CONFIG_DIR it is ~/.claude; a slug over 200 characters or no session tag imports nothing',
    () async {
      final data = '${tmp.path}/data';
      final importer = ClaudeImporter(
        driver: ClaudeDriver(dataDir: () async => data),
        env: (name) async => name == 'HOME' ? '${tmp.path}/home' : null,
      );
      expect(await importer.write(source(sessionTag: '')), isNull);
      final deep = '${tmp.path}/${'d' * 210}';
      Directory(deep).createSync();
      expect(await importer.write(source(dir: deep)), isNull);
      expect(Directory('${tmp.path}/home').existsSync(), isFalse);
      expect(Directory(data).existsSync(), isFalse);
      final ok = await importer.write(source(dir: work));
      expect(
        File('${tmp.path}/home/.claude/projects/${claudeProjectSlug(work)}/${ok!.nativeId}.jsonl').existsSync(),
        isTrue,
      );
    },
  );
}
