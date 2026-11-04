import 'dart:io';

import 'package:every_ai/features/code/drivers/event_journal.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('events survive a reopen; deltas and torn lines are skipped', () async {
    final dir = await Directory.systemTemp.createTemp('journal');
    addTearDown(() => dir.delete(recursive: true));
    final j = openEventJournal(dir.path, 'conv/1');
    j.add(
      HarnessEvent.decode({
        'kind': 'MessageEvent',
        'id': 'a',
        'source': 'user',
        'llm_message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        },
      }),
    );
    j.add(
      HarnessEvent.decode({
        'kind': 'ConversationStateUpdateEvent',
        'id': 'b',
        'key': 'execution_status',
        'value': 'finished',
      }),
    );
    await j.close();
    File('${dir.path}/conv_1.jsonl').writeAsStringSync('{"kind":"Mess', mode: FileMode.append);
    final events = await openEventJournal(dir.path, 'conv/1').read();
    expect(events.map((e) => e.id), ['a', 'b']);
    expect(events.first, isA<ChatMessage>());
  });
}
