// Fakes for Code sessions led by outside agents: a scriptable session, a
// driver over it, and the MCP host. Shared by the lead tests.

import 'dart:async';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

class FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

/// The first value of [p] that meets [cond], now or when it changes.
Future<T> whenValue<T>(ProviderContainer c, ProviderListenable<T> p, bool Function(T) cond) {
  final done = Completer<T>();
  final sub = c.listen<T>(p, (_, v) {
    if (cond(v) && !done.isCompleted) done.complete(v);
  }, fireImmediately: true);
  return done.future.whenComplete(sub.close);
}

/// An outside agent's session: the test plays its events and reads what it
/// was sent and answered. With [replays], a new listener gets every event
/// played so far first, as a reopened conversation does.
final class FakeLeadSession implements HarnessSession, SteersRuns, HasNativeCommands, NativeModes {
  FakeLeadSession({this.id = 'c1', this.replays = false, List<HarnessEvent> history = const []}) {
    _history.addAll(history);
  }

  @override
  final String id;
  final bool replays;
  final _events = StreamController<HarnessEvent>.broadcast();
  final _history = <HarnessEvent>[];
  final answers = <({bool accept, String? reason})>[];
  final sent = <String>[];
  final steered = <String>[];
  var closed = false;
  var interrupts = 0;

  /// [close] throws (the CLI's exit failed).
  var closeFails = false;

  /// What [interrupt] plays (an agent that stops).
  List<HarnessEvent> onInterrupt = const [];

  List<HarnessEvent> get history => List.unmodifiable(_history);

  /// Its own `/` commands (the test sets them) and the ones run, as `name|args`.
  final nativeCommands = NativeCommandList();
  final ran = <String>[];
  @override
  Stream<List<NativeCommand>> get commands => nativeCommands.stream;
  @override
  Future<void> runCommand(String name, String args) async {
    if (runFails case final e?) throw e;
    ran.add('$name|$args');
  }

  /// What [runCommand] throws (a transport error of the driver's own).
  Object? runFails;

  /// Its own modes (empty until the test sets them: then the app's picker is
  /// ours) and the ones picked by name.
  final modeFeed = NativeModeFeed();
  final picked = <String>[];

  /// What [setNativeMode] throws.
  Object? pickFails;
  @override
  Stream<NativeModeSet> get nativeModes => modeFeed.stream;
  @override
  Future<void> setNativeMode(String id) async {
    if (pickFails case final e?) throw e;
    picked.add(id);
    modeFeed.set(current: id);
  }

  @override
  Stream<HarnessEvent> get events {
    if (!replays) return _events.stream;
    final old = [..._history];
    return Stream.multi((sink) {
      old.forEach(sink.add);
      final sub = _events.stream.listen(sink.add);
      sink.onCancel = sub.cancel;
    });
  }

  void add(HarnessEvent e) {
    _history.add(e);
    _events.add(e);
  }

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async =>
      answers.add((accept: accept, reason: reason));
  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async => sent.add(text);
  @override
  Future<void> steer(String text, {List<String> images = const []}) async => steered.add(text);
  @override
  Future<void> interrupt() async {
    interrupts++;
    onInterrupt.forEach(add);
  }

  @override
  Future<void> pause() async {}

  /// Times the app ran the agent again ([resume]) or gave it a new LLM ([switchLlm]).
  var resumes = 0;
  var llmSwitches = 0;
  @override
  Future<void> resume() async => resumes++;

  /// When set, [setMode] waits for it (an agent that takes the switch late).
  Completer<void>? modeGate;

  /// The modes the app set on it, in order.
  final modes = <AgentMode>[];
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {
    modes.add(mode);
    await modeGate?.future;
  }

  @override
  Future<void> switchLlm(SessionSpec spec) async => llmSwitches++;
  @override
  Future<void> rewindTo(String? head) async {}
  @override
  Future<void> close() async {
    closed = true;
    if (closeFails) throw const HarnessError('It would not exit.');
  }
}

/// A driver over fake sessions. Given [session], every start and attach
/// returns it; otherwise each start makes a new one (`<id>-c1`, `<id>-c2`, …)
/// and attach reopens it, replaying what it played ([attachFails] refuses).
final class FakeLeadDriver implements HarnessDriver, AttachesBriefed, ChecksResume {
  FakeLeadDriver(
    this.id, {
    this.session,
    this.needsConsent = false,
    this.caps = const {DriverCap.approvals},
    this.label = 'Test CLI',
    this.status = const DriverStatus(installed: true),
    this.consentId,
  });

  final String id;

  /// Where its consent is stored, when not under [id] (an ACP profile).
  final String? consentId;
  final FakeLeadSession? session;
  final bool needsConsent;
  final String label;
  final DriverStatus status;
  @override
  final Set<DriverCap> caps;
  final specs = <SessionSpec>[];
  final reopened = <DriverBriefing>[];
  final reopenedMcp = <Map<String, Object?>>[];
  final attached = <String>[];
  final conversations = <String, FakeLeadSession>{};
  var attachFails = false;

  /// What [resumeProblem] says (null: it can be resumed).
  String? problem;

  @override
  Future<String?> resumeProblem(String conversationId) async => problem;

  /// [start] throws (the CLI didn't start).
  var startFails = false;

  /// [start] waits for it (a slow start, to act while a switch is under way).
  Completer<void>? startGate;

  /// The newest conversation started or reopened.
  FakeLeadSession? latest;

  @override
  DriverInfo get info => DriverInfo(id: id, label: label, needsConsent: needsConsent, consentId: consentId);

  /// When set, [detect] waits for it (harness detection still running).
  Completer<void>? detectGate;
  @override
  Future<DriverStatus> detect() async {
    await detectGate?.future;
    return status;
  }

  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    specs.add(spec);
    if (startGate case final gate?) await gate.future;
    if (startFails) throw const HarnessError('It failed to start.');
    if (session case final s?) return s;
    final s = latest = FakeLeadSession(id: '$id-c${conversations.length + 1}', replays: true);
    conversations[s.id] = s;
    if (spec.initialMessage case final text?) s.sent.add(text);
    return s;
  }

  @override
  Future<HarnessSession> attach(String conversationId) => _attach(conversationId);
  @override
  Future<HarnessSession> attachBriefed(
    String conversationId,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  }) {
    reopened.add(briefing);
    reopenedMcp.add(mcpConfig);
    return _attach(conversationId);
  }

  Future<HarnessSession> _attach(String conversationId) async {
    attached.add(conversationId);
    if (session case final s?) return s;
    if (attachFails) throw const HarnessError('That conversation is gone.');
    final old = conversations[conversationId];
    if (old == null) throw const HarnessError('No such conversation.');
    return latest = conversations[conversationId] = FakeLeadSession(
      id: conversationId,
      replays: true,
      history: old.history,
    );
  }

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

/// The MCP host: records tokens and hands the test each session's tools.
final class FakeHost implements HostServer {
  final minted = <String>[];
  final revoked = <String>[];
  final revokedSessions = <String>[];
  final tools = <String, HostTools>{};

  /// Live tokens by session; a revoked one leaves.
  final live = <String, Set<String>>{};
  var touchOk = true;
  var _n = 0;

  @override
  Future<HostToken> mint(String sessionId, HostTools tools, {bool bugFix = false}) async {
    minted.add(sessionId);
    this.tools[sessionId] = tools;
    final token = 'tok${++_n}';
    (live[sessionId] ??= {}).add(token);
    return (url: Uri.parse('http://127.0.0.1:9/mcp'), token: token);
  }

  @override
  bool touch(String token) => touchOk;
  @override
  Future<void> revoke(String token) async {
    revoked.add(token);
    for (final t in live.values) {
      t.remove(token);
    }
  }

  @override
  Future<void> revokeSession(String sessionId) async {
    revokedSessions.add(sessionId);
    revoked.addAll(live.remove(sessionId) ?? const {});
  }

  @override
  Future<void> stop() async {}
}
