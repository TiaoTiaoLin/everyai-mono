import 'dart:async';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_error.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_titles.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/chat/domain/suggest_mode.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A transport the test drives by hand: each send() opens a controller.
class FakeTransport implements ChatTransport {
  final requests = <ChatRequest>[];
  final turns = <StreamController<ChatEvent>>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) {
    requests.add(request);
    final turn = StreamController<ChatEvent>();
    turns.add(turn);
    cancel?.then((_) {
      if (!turn.isClosed) {
        turn.addError(const CancelledError());
        turn.close();
      }
    });
    return turn.stream;
  }
}

/// Records answers to client-executed tools; [delivered] is what the server says.
class FakeToolResults implements ToolResults {
  final answers = <(String, Object?, bool)>[];
  bool delivered = true;

  @override
  Future<bool> resolve(String callId, Object? result, {bool isError = false}) async {
    answers.add((callId, result, isError));
    return delivered;
  }
}

/// Answers title requests with [reply] (null: the call failed).
class FakeTitler implements ChatTitler {
  final calls = <(String, String, String)>[];
  String? reply;
  Completer<void>? gate;

  @override
  Future<String?> title({
    required String user,
    required String assistant,
    required String session,
    Map<String, String> headers = const {},
  }) async {
    calls.add((user, assistant, session));
    await gate?.future;
    return reply;
  }
}

/// The built-in catalog, without the network refresh.
class FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late FakeToolResults results;
  late FakeTitler titler;
  late ProviderContainer container;
  const id = 'conv-1';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    transport = FakeTransport();
    results = FakeToolResults();
    titler = FakeTitler();
    final prefs = await Preferences.load(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        installedSkillsProvider.overrideWith(NoInstalledSkills.new),
        chatTransportProvider.overrideWithValue(transport),
        toolResultsProvider.overrideWithValue(results),
        chatTitlerProvider.overrideWithValue(titler),
        chatClientToolsProvider.overrideWithValue(const {'render_diagram'}),
        // Checks math only: no webview draws Mermaid in tests.
        appToolCheckerProvider.overrideWithValue(const AppToolChecker()),
        modelCatalogProvider.overrideWith(FixedCatalog.new),
      ],
    );
    // Keep the auto-dispose family alive for the whole test.
    container.listen(chatSessionProvider(id), (_, _) {});
  });

  tearDown(() async {
    // Let fire-and-forget writes finish before the database closes.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    container.dispose();
    await db.close();
  });

  ChatSessionState state() => container.read(chatSessionProvider(id));
  ChatController ctl() => container.read(chatSessionProvider(id).notifier);
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('loads to Idle for a brand-new conversation', () async {
    expect(state().phase, isA<Loading>());
    await settle();
    expect(state().phase, isA<Idle>());
    expect(state().messages, isEmpty);
    expect(state().title, isNull);
  });

  test('send → Awaiting → Streaming → Idle, persisted with title', () async {
    await settle();
    await ctl().send('Hello there');
    expect(state().phase, isA<Awaiting>());
    expect(state().messages.map((m) => m.role), [Role.user, Role.assistant]);
    expect(state().title, 'Hello there');

    transport.turns.single.add(const TextDelta('Hi'));
    await settle();
    expect(state().phase, isA<Streaming>());
    expect(state().streamingText, 'Hi');

    final listBefore = state().messages;
    transport.turns.single.add(const TextDelta(', friend'));
    await settle();
    expect(state().streamingText, 'Hi, friend');
    expect(identical(state().messages, listBefore), isTrue, reason: 'no list rebuild per token');

    transport.turns.single.add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();
    expect(state().phase, isA<Idle>());
    expect(state().streamingText, isEmpty);
    final assistant = state().messages.last;
    expect(assistant.status, MessageStatus.complete);
    expect(assistant.plainText, 'Hi, friend');

    final stored = await container.read(chatRepositoryProvider).messages(id);
    expect(stored.map((m) => (m.role, m.plainText, m.status)), [
      (Role.user, 'Hello there', MessageStatus.complete),
      (Role.assistant, 'Hi, friend', MessageStatus.complete),
    ]);
  });

  group('backend titles', () {
    Future<void> firstTurn(String prompt, String reply) async {
      await settle();
      await ctl().send(prompt);
      transport.turns.single
        ..add(TextDelta(reply))
        ..add(const TurnDone());
      unawaited(transport.turns.single.close());
      await settle();
    }

    Future<String?> stored() async => (await container.read(chatRepositoryProvider).conversation(id))?.title;

    test('the first reply renames the chat with the backend title', () async {
      titler.reply = 'Greeting a friend';
      await firstTurn('Hello there', 'Hi, friend');
      expect(titler.calls, [('Hello there', 'Hi, friend', id)]);
      expect(state().title, 'Greeting a friend');
      expect(await stored(), 'Greeting a friend');

      // Only the first reply asks.
      await ctl().send('again');
      transport.turns.last
        ..add(const TextDelta('ok'))
        ..add(const TurnDone());
      unawaited(transport.turns.last.close());
      await settle();
      expect(titler.calls, hasLength(1));
    });

    test('a failed title call keeps the local title', () async {
      await firstTurn('Hello there', 'Hi');
      expect(titler.calls, hasLength(1));
      expect(state().title, 'Hello there');
      expect(await stored(), 'Hello there');
    });

    test('a name the user gave meanwhile stays', () async {
      titler
        ..reply = 'Greeting a friend'
        ..gate = Completer<void>();
      await firstTurn('Hello there', 'Hi');
      await container.read(chatRepositoryProvider).rename(id, 'My chat');
      titler.gate!.complete();
      await settle();
      expect(await stored(), 'My chat');
    });

    test('a failed or cancelled turn asks nothing', () async {
      titler.reply = 'Nope';
      await settle();
      await ctl().send('flaky');
      transport.turns.single.addError(const TimeoutError());
      await settle();
      expect(titler.calls, isEmpty);
      expect(await stored(), 'flaky');
    });
  });

  test('a second send while busy is ignored', () async {
    await settle();
    await ctl().send('one');
    await ctl().send('two');
    expect(transport.requests, hasLength(1));
  });

  test('cancel keeps partial text and returns to Idle', () async {
    await settle();
    await ctl().send('long answer please');
    transport.turns.single.add(const TextDelta('Partial'));
    await settle();
    ctl().cancel();
    await settle();
    expect(state().phase, isA<Idle>());
    expect(state().messages.last.status, MessageStatus.cancelled);
    expect(state().messages.last.plainText, 'Partial');
  });

  test('error → Failed, then retry resends the same prompt and model', () async {
    await settle();
    await ctl().send('flaky');
    transport.turns.single.addError(const TimeoutError());
    await settle();
    final phase = state().phase;
    expect(phase, isA<Failed>());
    expect((phase as Failed).error, isA<TimeoutError>());

    await ctl().retry();
    expect(transport.requests, hasLength(2));
    expect(transport.requests.last.prompt, 'flaky');
    expect(state().messages.where((m) => m.status == MessageStatus.failed), isEmpty);
    expect(state().messages.where((m) => m.role == Role.user), hasLength(1));
  });

  test('@mention routes one message to another model and records it', () async {
    await settle();
    final defaultModel = state().model;
    await ctl().send('@claude summarize this');
    final request = transport.requests.single;
    expect(request.model.provider, ModelProvider.anthropic);
    expect(request.prompt, 'summarize this');
    expect(state().messages.last.model, request.model.id);
    expect(state().model, defaultModel, reason: 'override is one-shot');
  });

  test('tool calls keep their place among text; sources append; reasoning and session are kept', () async {
    await settle();
    await ctl().send('quiz me');
    expect(transport.requests.single.conversationId, id);
    final turn = transport.turns.single
      ..add(const ReasoningDelta('Plan a quiz.'))
      ..add(SourcesFound([Source(url: Uri.parse('https://a.dev'), title: 'A')]))
      ..add(const TextDelta("Here's a quiz."))
      ..add(const UiToolCall(id: 't1', name: 'make_quiz', argumentsJson: '{"title":"Q","questions":[]}'))
      ..add(const ToolProgress(id: 't2', name: 'web_fetch', status: ToolRunStatus.running, detail: 'https://b.dev/x'));
    await settle();
    expect(state().liveParts, hasLength(2)); // the text before the call, then the call
    expect(state().streamingText, isEmpty);
    expect(state().toolStatus, 'Reading b.dev…');
    expect(state().liveTools.single.detail, 'https://b.dev/x');
    turn
      ..add(SourcesFound([Source(url: Uri.parse('https://b.dev'), title: 'B')]))
      ..add(const TextDelta('Good luck [2]'))
      ..add(const FollowUpsSuggested(['More?']))
      ..add(const TurnDone());
    unawaited(turn.close());
    await settle();

    final parts = state().messages.last.parts;
    expect(parts.map((p) => p.runtimeType.toString()), [
      'ReasoningPart',
      'SourcesPart',
      'TextPart',
      'ToolCallPart',
      'TextPart',
      'FollowUpsPart',
    ]);
    expect(state().messages.last.sources.map((s) => s.title), ['A', 'B']);
    expect((parts[3] as ToolCallPart).callId, 't1');
    expect(state().toolStatus, isEmpty);
    expect(state().liveTools, isEmpty);

    // Round-trips through the database.
    container.invalidate(chatSessionProvider(id));
    container.listen(chatSessionProvider(id), (_, _) {});
    await settle();
    final reloaded = state().messages.last.parts;
    expect(reloaded.whereType<ToolCallPart>().single.toolName, 'make_quiz');
    expect(reloaded.whereType<ReasoningPart>().single.text, 'Plan a quiz.');
  });

  test('a 402 fails the turn with an out-of-credits error', () async {
    await settle();
    await ctl().send('hi');
    transport.turns.single.addError(const HttpStatusError(402, 'Out of credits', code: 'out_of_credits'));
    await settle();
    final phase = state().phase as Failed;
    expect((phase.error as HttpStatusError).outOfCredits, isTrue);
  });

  test('reopening a conversation restores its messages', () async {
    await settle();
    await ctl().send('persist me');
    transport.turns.single
      ..add(const TextDelta('ok'))
      ..add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();

    container.invalidate(chatSessionProvider(id));
    container.read(chatSessionProvider(id));
    await settle();
    expect(state().phase, isA<Idle>());
    expect(state().messages.map((m) => m.plainText), ['persist me', 'ok']);
    expect(state().title, 'persist me');
  });

  test('usage sums per turn, survives a reopen; follow-ups cost but leave the context reading alone', () async {
    await settle();
    await ctl().send('quiz me');
    transport.turns.single
      ..add(
        const UsageReport(
          promptTokens: 1000,
          completionTokens: 50,
          cachedTokens: 0,
          cacheWriteTokens: 900,
          chargedMicros: 300,
        ),
      )
      ..add(const TextDelta('done'))
      ..add(const UsageReport(promptTokens: 1100, completionTokens: 20, cachedTokens: 900, chargedMicros: 40));
    await settle();
    expect(state().usage.calls, 2);
    expect(state().usage.contextTokens, 1120);
    transport.turns.single
      ..add(
        const UsageReport(promptTokens: 80, completionTokens: 10, cachedTokens: 0, chargedMicros: 5, followUps: true),
      )
      ..add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();

    container.invalidate(chatSessionProvider(id));
    container.read(chatSessionProvider(id));
    await settle();
    final u = state().usage;
    expect(u.calls, 3);
    expect(u.promptTokens, 2180);
    expect(u.cachedTokens, 900);
    expect(u.cacheWriteTokens, 900);
    expect(u.chargedMicros, 345);
    expect(u.contextTokens, 1120);
  });

  Future<void> answer(String text) async {
    transport.turns.last
      ..add(TextDelta(text))
      ..add(const TurnDone());
    unawaited(transport.turns.last.close());
    await settle();
  }

  test('regenerate drops the last answer and asks again, optionally with another model', () async {
    await settle();
    await ctl().send('question');
    await answer('first');
    final claude = container.read(modelCatalogProvider).byProvider(ModelProvider.anthropic).first;

    await ctl().regenerate(model: claude);
    expect(transport.requests, hasLength(2));
    expect(transport.requests.last.prompt, 'question');
    expect(transport.requests.last.model, claude);
    await answer('second');

    expect(state().messages.map((m) => m.plainText), ['question', 'second']);
    final stored = await container.read(chatRepositoryProvider).messages(id);
    expect(stored.map((m) => m.plainText), ['question', 'second'], reason: 'old answer deleted from the DB');
  });

  test('editAndResend replaces the message and everything after it', () async {
    await settle();
    await ctl().send('one');
    await answer('a1');
    await ctl().send('two');
    await answer('a2');

    final first = state().messages.first;
    await ctl().editAndResend(first.id, 'one, edited');
    await answer('b1');

    expect(state().messages.map((m) => m.plainText), ['one, edited', 'b1']);
    final stored = await container.read(chatRepositoryProvider).messages(id);
    expect(stored.map((m) => m.plainText), ['one, edited', 'b1']);
  });

  test('mode is sent with the request; sources and follow-ups are stored as parts', () async {
    await settle();
    ctl().setMode(ChatMode.search);
    await ctl().send('latest news');
    expect(transport.requests.single.mode, ChatMode.search);

    final source = Source(url: Uri.parse('https://example.com/a'), title: 'Example');
    transport.turns.single.add(SourcesFound([source]));
    await settle();
    expect(state().liveSources, hasLength(1), reason: 'sources show before text arrives');

    transport.turns.single
      ..add(const TextDelta('Answer [1]'))
      ..add(const FollowUpsSuggested(['And then?']))
      ..add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();

    final last = state().messages.last;
    expect(last.parts.map((p) => p.runtimeType), [SourcesPart, TextPart, FollowUpsPart]);
    expect(state().liveSources, isEmpty);

    container.invalidate(chatSessionProvider(id));
    container.read(chatSessionProvider(id));
    await settle();
    final reloaded = state().messages.last;
    expect(reloaded.sources.single.url, source.url);
    expect((reloaded.parts.last as FollowUpsPart).questions, ['And then?']);
  });

  test('a suggested mode asks the last question again in that mode and keeps the first answer', () async {
    await settle();
    await ctl().send('explain photosynthesis');
    await answer('short answer');
    expect(
      suggestedMode(
        const ToolCallPart(
          callId: 's',
          toolName: suggestModeTool,
          argumentsJson: '{"mode":"learn","reason":"step by step with a quiz"}',
        ),
      ),
      (mode: ChatMode.learn, reason: 'step by step with a quiz'),
    );

    await ctl().rerunIn(ChatMode.learn);
    expect(transport.requests.last.mode, ChatMode.learn);
    expect(transport.requests.last.prompt, 'explain photosynthesis');
    await answer('lesson');
    expect(state().messages.map((m) => m.plainText), [
      'explain photosynthesis',
      'short answer',
      'explain photosynthesis',
      'lesson',
    ]);
    expect(state().mode, ChatMode.learn);
  });

  test('Auto: the route is kept on the answer, survives a reopen, and a re-run uses the picked model', () async {
    await settle();
    ctl().selectModel(builtInCatalog.resolve(autoModelId));
    await ctl().send('what happened in Lyon today?');
    expect(transport.requests.last.model.id, autoModelId);
    expect(transport.requests.last.effort, isNull);
    transport.turns.last.add(
      const RouteChosen(model: ModelId('anthropic/claude-sonnet-5.5'), mode: ChatMode.search, toolsEnabled: true),
    );
    await settle();
    expect(state().liveParts.whereType<RoutePart>().single.mode, ChatMode.search);
    await answer('news');
    final reply = state().messages.last;
    expect(reply.model, autoModelId);
    expect(reply.route?.model, const ModelId('anthropic/claude-sonnet-5.5'));

    container.invalidate(chatSessionProvider(id));
    container.read(chatSessionProvider(id));
    await settle();
    final reopened = state().messages.last.route!;
    expect(
      (reopened.model.value, reopened.mode, reopened.toolsEnabled),
      ('anthropic/claude-sonnet-5.5', ChatMode.search, true),
    );
    expect(state().model.id, autoModelId);

    await ctl().rerunIn(ChatMode.research, model: builtInCatalog.resolve(reopened.model));
    expect(transport.requests.last.mode, ChatMode.research);
    expect(transport.requests.last.model.id, const ModelId('anthropic/claude-sonnet-5.5'));
    // The chat stays on Auto.
    expect(state().model.id, autoModelId);
  });

  test('Research sends the chosen depth', () async {
    await settle();
    ctl()
      ..setMode(ChatMode.research)
      ..setResearchDepth(ResearchDepth.deep);
    await ctl().send('compare heat pumps');
    expect(transport.requests.single.mode, ChatMode.research);
    expect(transport.requests.single.researchDepth, ResearchDepth.deep);
  });

  test('client-executed tools: declared, rendered, pending until resolved or the server gives up', () async {
    await settle();
    await ctl().send('draw it');
    expect(transport.requests.single.clientTools, {'render_diagram'});

    const args = '{"mermaid":"graph TD; A-->B"}';
    transport.turns.single
      ..add(const ToolWait(id: 'call_1', name: 'render_diagram', argumentsJson: args))
      ..add(const ToolWait(id: 'call_2', name: 'render_diagram', argumentsJson: args));
    await settle();
    expect(state().pendingTools.map((t) => t.id), ['call_1', 'call_2']);
    expect(state().liveParts.whereType<ToolCallPart>().map((p) => p.callId), ['call_1', 'call_2']);

    expect(await ctl().resolveTool('call_1', 'Rendered.'), isTrue);
    expect(results.answers.single, ('call_1', 'Rendered.', false));
    expect(state().pendingTools.map((t) => t.id), ['call_2']);
    // Not pending (any more): nothing is sent.
    expect(await ctl().resolveTool('call_1', 'again'), isFalse);
    expect(results.answers, hasLength(1));

    // The server timed out the other one: it is no longer pending, and not a server-tool row.
    transport.turns.single.add(
      const ToolProgress(id: 'call_2', name: 'render_diagram', status: ToolRunStatus.failed, detail: 'timed out'),
    );
    await settle();
    expect(state().pendingTools, isEmpty);
    expect(state().liveTools, isEmpty);

    transport.turns.single
      ..add(const TextDelta('Done'))
      ..add(const TurnDone());
    unawaited(transport.turns.single.close());
    await settle();
    expect(state().messages.last.parts.whereType<ToolCallPart>(), hasLength(2));
  });

  test('artifact calls the app checks are answered with what the check found', () async {
    await settle();
    await ctl().send('write it up');
    transport.turns.single
      ..add(
        const ToolWait(
          id: 'call_1',
          name: 'create_artifact',
          argumentsJson: r'{"id":"n","title":"N","kind":"markdown","content":"Broken $\\frac{1}{$ math"}',
        ),
      )
      ..add(
        const ToolWait(
          id: 'call_2',
          name: 'create_artifact',
          argumentsJson: r'{"id":"m","title":"M","kind":"markdown","content":"Fine $x$"}',
        ),
      );
    await settle();
    expect(results.answers.map((a) => (a.$1, a.$3)), [('call_1', true), ('call_2', false)]);
    expect(results.answers.first.$2, contains('edit_artifact'));
    expect(state().pendingTools, isEmpty);
    // The server's closing status adds no step row for a checked visual.
    transport.turns.single.add(const ToolProgress(id: 'call_1', name: 'create_artifact', status: ToolRunStatus.failed));
    await settle();
    expect(state().liveTools, isEmpty);
  });

  test('without tools, no client tools are declared', () async {
    await settle();
    ctl().setToolsEnabled(false);
    await ctl().send('hi');
    expect(transport.requests.single.clientTools, isEmpty);
  });
}
