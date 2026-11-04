import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/compaction.dart' show userTextOf;
import 'package:every_ai/features/code/domain/rewind.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shaped like agent-server 1.59.0's log after three messages, a navigate
/// back to the first, and a fourth message (the probe in `domain/rewind.dart`).
Map<String, Object?> _ev(String id, String kind, String? parent, [String text = '']) => {
  'id': id,
  'kind': kind,
  'parent_id': parent,
  if (kind == 'MessageEvent') ...{
    'source': 'user',
    'llm_message': {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  },
  if (kind == 'ConversationStateUpdateEvent') ...{'key': 'last_user_message_id', 'value': parent},
};

final _branched = [
  _ev('sys', 'SystemPromptEvent', null),
  _ev('m1', 'MessageEvent', 'sys', 'one'),
  _ev('s1', 'ConversationStateUpdateEvent', 'm1'),
  _ev('m2', 'MessageEvent', 'm1', 'two'),
  _ev('s2', 'ConversationStateUpdateEvent', 'm2'),
  _ev('m3', 'MessageEvent', 'm2', 'three'),
  _ev('s3', 'ConversationStateUpdateEvent', 'm3'),
  _ev('m4', 'MessageEvent', 'm1', 'four'),
  _ev('s4', 'ConversationStateUpdateEvent', 'm4'),
];

List<HarnessEvent> _decoded(List<Map<String, Object?>> raw) => [for (final e in raw) HarnessEvent.decode(e)];
List<String> _ids(Iterable<HarnessEvent> events) => [for (final e in events) e.id];

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<T> _until<T>(T Function() read, bool Function(T) cond) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Map<String, Object?> _agent(String text) => {
  'kind': 'MessageEvent',
  'source': 'agent',
  'llm_message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

void main() {
  group('event tree', () {
    test('the active branch keeps the path to the head and its state updates', () {
      final events = _decoded(_branched);
      expect(_ids(activeBranch(events, 'm4')), ['sys', 'm1', 's1', 'm4', 's4']);
      expect(offBranch(events, 'm4'), {'m2', 's2', 'm3', 's3'});
      // A head inside a branch drops what came after it on that branch too.
      expect(_ids(activeBranch(events, 'm2')), ['sys', 'm1', 's1', 'm2', 's2']);
      expect(offBranch(events, null), isEmpty);
      // An unknown head leaves everything (nothing to go on).
      expect(activeBranch(events, 'nope').length, events.length);
    });

    test('rewinding before a message moves the head to its parent', () {
      final events = _decoded(_branched);
      expect(rewindHead(events, 'm4'), 'm1');
      expect(rewindHead(events, 'm1'), 'sys');
      expect(rewindHead(events, 'sys'), isNull);
      expect(() => rewindHead(events, 'nope'), throwsArgumentError);
      expect(_ids(rewound(events, 'm1')), ['sys', 'm1', 's1']);
      expect(rewound(events, null), isEmpty);
    });

    test('events without parent ids chain in order, as on older servers', () {
      final events = _decoded([
        for (final e in _branched.take(6)) {...e}..remove('parent_id'),
      ]);
      expect(rewindHead(events, 'm3'), 'm2');
      expect(_ids(activeBranch(events, 'm2')), ['sys', 'm1', 's1', 'm2', 's2']);
    });

    test('labels', () {
      expect(
        const RewindOutcome(kind: RewindKind.done, conversation: true, files: true).label,
        'Rewound the conversation and the files.',
      );
      expect(const RewindOutcome.busy().label, contains('stop it'));
      expect(rewindPrompt('this message', files: false), contains('The files stay as they are.'));
      final filesOnly = rewindPrompt('this message', files: true, conversation: false);
      expect(filesOnly, contains('files back'));
      expect(filesOnly, isNot(contains('forgets')));
    });

    test('the note for a harness that kept the conversation', () {
      final note = rewindNote('  Add a\n  decrement method ');
      expect(note, rewindNote('Add a decrement method'));
      expect(note, startsWith('<everyai-rewind>'));
      expect(note, contains('"Add a decrement method"'));
      expect(rewindNote('x' * 200), contains('${'x' * 80}…"'));
    });

    test('the note comes off the echoed message', () {
      expect(splitRewindNote('${rewindNote('Add a file')}\n\ntry again'), 'try again');
      expect(splitRewindNote('try again'), 'try again');
      expect(userTextOf(modeNote(AgentMode.ask, '${rewindNote('Add a file')}\n\ntry again', full: true)), 'try again');
    });
  });

  group('controller', () {
    late AppDatabase db;
    late ProviderContainer container;
    late FakeHarness harness;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([
        const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
      ]);
      harness = FakeHarness(
        step: Duration.zero,
        turns: [
          [_agent('reply one')],
          [_agent('reply two')],
          [_agent('reply three')],
        ],
      );
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          harnessProvider.overrideWithValue(harness),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('rewinding forgets the later turns and the next message branches from there', () async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'first',
            model: 'anthropic/claude-haiku-5.5',
            mode: AgentMode.fullAuto,
          );
      final id = info.id;
      container.listen(codeSessionProvider(id), (_, _) {});
      Transcript t() => container.read(codeSessionProvider(id)).transcript;
      List<String> said() => [
        for (final item in t().items)
          if (item is UserTurn) 'user:${item.text}' else if (item is AgentText) 'agent:${item.text}',
      ];
      final controller = container.read(codeSessionProvider(id).notifier);

      await _until(said, (s) => s.contains('agent:reply one'));
      await controller.send('second');
      await _until(said, (s) => s.contains('agent:reply two'));
      await controller.send('third');
      await _until(said, (s) => s.contains('agent:reply three'));

      final outcome = await controller.rewind(2);
      expect(outcome.kind, RewindKind.done);
      expect(outcome.conversation, isTrue);
      expect(outcome.files, isFalse);
      expect(said(), ['user:first', 'agent:reply one']);
      expect(t().running, isFalse);
      // The head went to the reply before "second".
      final head = harness.rewinds.single;
      expect(head, isNotNull);

      // The script carries on from turn two, on the new branch.
      await controller.send('second, again');
      await _until(said, (s) => s.length == 4);
      expect(said(), ['user:first', 'agent:reply one', 'user:second, again', 'agent:reply two']);

      expect((await controller.rewind(9)).kind, RewindKind.nothing);
      final first = await controller.rewind(1);
      expect(first.conversation, isTrue);
      expect(said(), isEmpty);
      expect(harness.rewinds.last, isNull);
    });
  });
}
