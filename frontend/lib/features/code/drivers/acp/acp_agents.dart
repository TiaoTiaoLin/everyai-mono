// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../briefing/briefing_types.dart';
import '../briefing/recipes.dart' as recipes;
import '../driver.dart';
import 'acp_files.dart';

// What the app knows about each ACP agent it drives. One generic client
// serves them all; an entry pins the flags and modes that keep an agent
// asking (Gemini can start in its yolo mode, OpenCode and goose never ask by
// default) and says how to tell it is signed in without a model call.
// Agents without logic of their own are [AcpAgent.generic] plus data.

/// The agents with logic of their own; anything else is [generic].
enum AcpAgent { gemini, openCode, qwen, kiro, cursor, grok, generic }

/// How to run one ACP agent so every risky call comes to the app as a
/// `session/request_permission`.
@immutable
final class AcpProfile {
  const AcpProfile._({
    required this.agent,
    required this.pinned,
    required this.caps,
    required this.signIn,
    this.dropped = const [],
    this.droppedWithValue = const [],
    this.extraEnv = const {},
    this.askMode,
    this.planMode,
    this.lateReplay = false,
    this.minVersion,
    this.keyEnv = const [],
    this.needsConsent = false,
    this.configPins = const {},
    this.notThis,
    this.alsoNamed = const [],
    this.ttyFallback = false,
    this.initializeMeta,
    this.cancelMeta,
  });

  final AcpAgent agent;

  /// Arguments it always runs with, as flag groups (a flag and its values, or
  /// a subcommand). One replaces the same flag given in the command.
  final List<List<String>> pinned;

  /// Flags removed from the command (they would skip the agent's prompts).
  final List<String> dropped;

  /// Like [dropped], for flags that take a value: `--auto high` loses both.
  final List<String> droppedWithValue;

  /// Environment it always runs with (auto-update off, its asking mode).
  final Map<String, String> extraEnv;
  final Set<DriverCap> caps;

  /// The agent's own mode that asks before acting, set for every app mode
  /// but Plan; null leaves its modes alone.
  final String? askMode;

  /// Its read-only mode, for Plan (when it has one).
  final String? planMode;

  /// What the user does to sign in, as an instruction.
  final String signIn;

  /// Whether its `session/load` replay can still be streaming after the
  /// reply (Gemini doesn't wait for it), so the first prompt waits for quiet.
  final bool lateReplay;

  /// The oldest version that runs as pinned (`x.y.z`); older ones show a
  /// problem in [acpVersionProblem].
  final String? minVersion;

  /// Environment variables holding its API key: any one set counts as
  /// signed in (only presence is checked).
  final List<String> keyEnv;

  /// Whether the user must turn on "Use my own installed CLIs" for it: its
  /// vendor's terms leave a third-party client on the user's sign-in open.
  final bool needsConsent;

  /// Session config options set by id whatever the agent starts with, kept
  /// there when it changes them back (Kiro's `autopilot` runs tools unasked).
  final Map<String, String> configPins;

  /// A pattern for a `--version` line that shows the command is another
  /// program of the same name, and what to tell the user then.
  final ({String line, String problem})? notThis;

  /// Other names the same CLI installs under, looked up on PATH in order
  /// when the command's own name isn't found.
  final List<String> alsoNamed;

  /// Whether it may need a terminal of its own: when it exits saying it
  /// couldn't open one (`isNoTtyExit`), it starts again under a pty.
  final bool ttyFallback;

  /// `_meta` for `initialize` and for `session/cancel`, when it reads one.
  final Map<String, Object?>? initializeMeta;
  final Map<String, Object?>? cancelMeta;

  /// The `authenticate` method to try once when `session/new` says it isn't
  /// signed in, read from the login environment [env]; null tries none.
  Future<String?> authMethod(Future<Map<String, String>> Function() env) async => switch (agent) {
    // Ported from T3 Code (MIT), packages/provider-grok/src/server/acpSupport.ts `resolveGrokAuthMethodId`.
    AcpAgent.grok => ((await env())['XAI_API_KEY'] ?? '').trim().isNotEmpty ? 'xai.api_key' : 'cached_token',
    _ => null,
  };

  /// How the session's briefing reaches it (`drivers/briefing/recipes.dart`).
  Delivery deliver(BriefingInput i, List<({String name, String description})> skills) => switch (agent) {
    AcpAgent.gemini => recipes.gemini(i, skills: skills),
    AcpAgent.openCode => recipes.openCode(i),
    _ => recipes.acp(i, skills: skills),
  };

  /// Its environment on top of [delivery]'s: OpenCode gets [openCodePermissions].
  Map<String, String> env(Delivery? delivery) => switch (agent) {
    AcpAgent.openCode => withOpenCodePermissions({...extraEnv, ...?delivery?.env}),
    _ => {...extraEnv, ...?delivery?.env},
  };

  /// Whether the session's MCP server goes in the agent's config ([env])
  /// rather than in `session/new`.
  bool get mcpInConfig => agent == AcpAgent.openCode;

  /// Why it must not start in [cwd] (project files that would let it act
  /// without asking), or null.
  Future<String?> preflight(String cwd) => switch (agent) {
    AcpAgent.gemini => geminiWorkspaceProblem(cwd),
    AcpAgent.qwen => geminiWorkspaceProblem(cwd, folder: '.qwen', label: 'Qwen Code'),
    AcpAgent.kiro => kiroWorkspaceProblem(cwd),
    AcpAgent.cursor => cursorWorkspaceProblem(cwd),
    _ => Future.value(),
  };

  /// This profile with [env] (an ACP registry entry's) under its own
  /// [extraEnv]: on a clash the profile's value wins, so a registry entry
  /// can't undo a pin that keeps the agent asking.
  AcpProfile withEnv(Map<String, String> env) => env.isEmpty
      ? this
      : AcpProfile._(
          agent: agent,
          pinned: pinned,
          caps: caps,
          signIn: signIn,
          dropped: dropped,
          droppedWithValue: droppedWithValue,
          extraEnv: {...env, ...extraEnv},
          askMode: askMode,
          planMode: planMode,
          lateReplay: lateReplay,
          minVersion: minVersion,
          keyEnv: keyEnv,
          needsConsent: needsConsent,
          configPins: configPins,
          notThis: notThis,
          alsoNamed: alsoNamed,
          ttyFallback: ttyFallback,
          initializeMeta: initializeMeta,
          cancelMeta: cancelMeta,
        );

  /// Whether this is one of the profiles above (not [generic]'s).
  bool get known => !identical(this, _generic);

  /// Whether it is signed in, without a model call; null when it can't tell.
  /// [env] replaces the login environment (tests).
  Future<bool?> signedIn(String executable, {Map<String, String>? env}) async {
    if (keyEnv.isNotEmpty && await envHasAny(keyEnv, env: env)) return true;
    return switch (agent) {
      AcpAgent.gemini => geminiSignedIn(env: env),
      AcpAgent.openCode => openCodeSignedIn(executable),
      AcpAgent.kiro => kiroSignedIn(executable),
      AcpAgent.cursor => cursorSignedIn(),
      AcpAgent.grok => grokSignedIn(executable),
      _ => null,
    };
  }
}

/// Why [versionLine] (its `--version` output) is too old for [p], or null.
/// A line without an `x.y.z` never blocks.
String? acpVersionProblem(AcpProfile p, String label, String? versionLine) {
  final min = p.minVersion;
  if (min == null || versionLine == null) return null;
  final found = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(versionLine);
  if (found == null) return null;
  final have = [for (var g = 1; g <= 3; g++) int.parse(found.group(g)!)];
  final want = [for (final part in min.split('.')) int.parse(part)];
  for (var i = 0; i < 3; i++) {
    if (have[i] != want[i]) {
      return have[i] > want[i] ? null : '$label ${found.group(0)} is too old: update to $min or later.';
    }
  }
  return null;
}

/// Why [versionLine] shows the command at [path] isn't the agent of [p]
/// (another program with the same name), or null. Cursor's generic `agent`
/// name must print Cursor's dated version (`2026.10.22-…`).
String? acpForeignProblem(AcpProfile p, String? versionLine, {String? path}) {
  if (versionLine == null) return null;
  if (p.agent == AcpAgent.cursor && path?.split('/').last == 'agent') {
    return RegExp(r'\b20\d\d\.\d\d\.\d\d\b').hasMatch(versionLine)
        ? null
        : 'This `agent` is another program, not Cursor CLI.';
  }
  return p.notThis != null && RegExp(p.notThis!.line).hasMatch(versionLine) ? p.notThis!.problem : null;
}

/// Whether `kiro-cli whoami --format json` exiting with [code] and [stdout]
/// means signed in: exit 0 is, `{"account":null}` with an error isn't, and
/// anything else is unknown (null).
// Ported from T3 Code (MIT), packages/provider-kiro/src/server/status.ts `kiroAuthFromWhoami`.
bool? kiroSignedInFrom(int code, String stdout) {
  if (code == 0) return true;
  return stdout.contains('"account":null') ? false : null;
}

/// Whether `security find-generic-password -s cursor-access-token -a
/// cursor-user` (attributes only, never the secret) exiting with [code]
/// means Cursor CLI is signed in: 0 found the entry, 44 found none, anything
/// else is unknown (null).
// The entry's name is from T3 Code (MIT), packages/provider-cursor/src/server/CursorKeychain.ts.
bool? cursorSignedInFrom(int code) => switch (code) {
  0 => true,
  44 => false,
  _ => null,
};

const _asks = {DriverCap.approvals, DriverCap.perCallApprovals};
const _shared = {DriverCap.resume, ..._asks};

const _gemini = AcpProfile._(
  agent: AcpAgent.gemini,
  // `--acp` (0.33.2; `--experimental-acp` is its deprecated alias). The
  // approval mode pins the asking mode whatever the user's settings say.
  pinned: [
    ['--acp'],
    ['--approval-mode', 'default'],
  ],
  // Gemini refuses --yolo next to --approval-mode.
  dropped: ['--yolo', '-y'],
  caps: {..._shared, DriverCap.mcp, DriverCap.images, DriverCap.switchModel, DriverCap.skills},
  askMode: 'default',
  // Personal Google sign-in stopped working on 2026-06-18 (Antigravity CLI
  // took its place); keys and Code Assist licences still work.
  signIn:
      'Set GEMINI_API_KEY, or sign in with a Code Assist Standard or Enterprise licence '
      '(personal Google sign-in stopped working on 2026-06-18)',
  lateReplay: true,
  // Google's terms (Antigravity Additional Terms §6) name Gemini CLI accounts
  // and leave third-party clients on them open.
  needsConsent: true,
);

const _openCode = AcpProfile._(
  agent: AcpAgent.openCode,
  pinned: [
    ['acp'],
  ],
  caps: {
    ..._shared,
    DriverCap.mcp,
    DriverCap.images,
    DriverCap.switchModel,
    DriverCap.effort,
    DriverCap.usage,
    DriverCap.skills,
    DriverCap.subagents,
  },
  askMode: 'build',
  planMode: 'plan',
  signIn: 'Run `opencode auth login` in a terminal',
);

// Antigravity CLI: `agy acp` arrived in agy 1.5.0 (its release notes; the
// ACP registry still lists only the older antigravity-acp 1.4.5). It offers
// session/resume, not session/load, so no resume here. No consent gate: the
// owner decided (2026-11-04) that agy ships on consumer logins.
const _antigravity = AcpProfile._(
  agent: AcpAgent.generic,
  pinned: [
    ['acp'],
  ],
  caps: {..._asks, DriverCap.images},
  askMode: 'default',
  planMode: 'plan',
  signIn: 'Run `agy` in a terminal and sign in, or `agy acp --login` without a browser',
  minVersion: '1.5.0',
);

// GitHub Copilot CLI (docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server).
// Tools, effort and the sandbox (`--available-tools`, `--effort`,
// `--sandbox`) are flags of the process, set for every session: changing one
// means a new session. No consent: GitHub documents the ACP server for
// third-party clients.
const _copilot = AcpProfile._(
  agent: AcpAgent.generic,
  pinned: [
    ['--acp'],
    ['--stdio'],
  ],
  dropped: ['--yolo', '--allow-all', '--allow-all-tools', '--allow-all-paths', '--allow-all-urls'],
  droppedWithValue: ['--allow-tool', '--allow-url'],
  // The environment twin of --allow-all (docs: cli-programmatic-reference),
  // which a user's shell profile may set for terminal use.
  extraEnv: {'COPILOT_ALLOW_ALL': 'false'},
  caps: {..._shared, DriverCap.mcp},
  signIn: 'Run `copilot` in a terminal and use /login',
  // The AWS Copilot CLI is also `copilot` ("copilot version: v1.34.0").
  notThis: (line: _otherCli, problem: 'This `copilot` is another program (AWS Copilot?), not GitHub Copilot CLI.'),
);

// Kiro CLI (kiro.dev/docs/cli/acp/): `--agent-engine` needs 2.36; the v3
// engine sets model and mode through session/set_config_option. Signed out,
// it answers every request after initialize with auth-required. No consent:
// Kiro documents ACP for editors.
// Ported from T3 Code (MIT), packages/provider-kiro/src/server/acpSupport.ts:
// `--auth-method=cli` keeps the access tokens inside Kiro.
const _kiro = AcpProfile._(
  agent: AcpAgent.kiro,
  pinned: [
    ['acp'],
    ['--agent-engine=v3'],
    ['--auth-method=cli'],
  ],
  dropped: ['--trust-all-tools'],
  droppedWithValue: ['--agent-engine', '--trust-tools', '--auth-method'],
  caps: {..._asks, DriverCap.mcp},
  signIn: 'Run `kiro-cli login` in a terminal',
  minVersion: '2.36.0',
  keyEnv: ['KIRO_API_KEY'],
  // v3 starts with Autopilot on ("Agent executes tools without
  // confirmation"); off, every tool comes as a permission request. T3 Code's
  // `kiroAutopilotValue` turns it on only for full-access threads.
  configPins: {'autopilot': 'off'},
);

// Kimi Code CLI (MoonshotAI/kimi-code docs/en/reference/kimi-acp.md). Its
// questions arrive as permission requests. No consent: MIT, and ACP is
// documented for IDEs.
const _kimi = AcpProfile._(
  agent: AcpAgent.generic,
  pinned: [
    ['acp'],
  ],
  dropped: ['--yolo', '-y'],
  caps: {..._shared, DriverCap.mcp, DriverCap.switchModel},
  askMode: 'default',
  planMode: 'plan',
  signIn: 'Run `kimi` in a terminal and type /login',
);

// Qwen Code, a Gemini CLI fork: the same approval flags and a `.qwen`
// project folder. Mode ids are unverified. No consent: Apache-2.0, run on
// the user's own key.
const _qwen = AcpProfile._(
  agent: AcpAgent.qwen,
  pinned: [
    ['--acp'],
    ['--approval-mode', 'default'],
  ],
  dropped: ['--yolo', '-y'],
  caps: {..._asks, DriverCap.mcp},
  askMode: 'default',
  planMode: 'plan',
  signIn: 'Run `qwen` in a terminal and sign in, or set its API key',
  lateReplay: true,
);

// Cline CLI (cline/cline apps/cli): in ACP only an explicit
// `--auto-approve true` or `--yolo` approves on its own; the pin keeps it
// off. Modes are act and plan. No consent: Apache-2.0, ACP is a documented
// mode for editors.
const _cline = AcpProfile._(
  agent: AcpAgent.generic,
  pinned: [
    ['--acp'],
    ['--auto-approve', 'false'],
  ],
  dropped: ['--yolo', '-y', '--zen', '-z'],
  caps: _shared,
  askMode: 'act',
  planMode: 'plan',
  signIn: 'Run `cline auth` in a terminal',
);

// goose (aaif-goose/goose): its default mode, auto, never asks, so the
// environment and the session mode both pin `approve`. Its `chat` mode
// can't read files, so Plan relies on the app's rules. No consent:
// Apache-2.0, on the user's own provider key.
const _goose = AcpProfile._(
  agent: AcpAgent.generic,
  pinned: [
    ['acp'],
  ],
  extraEnv: {'GOOSE_MODE': 'approve'},
  caps: {..._shared, DriverCap.mcp},
  askMode: 'approve',
  signIn: 'Run `goose configure` in a terminal',
  // pressly's database-migration tool is also `goose` ("goose version: v3.26.0").
  notThis: (
    line: _otherCli,
    problem: "This `goose` is another program (the database-migration tool?), not Block's goose.",
  ),
);

// Mistral Vibe's ACP server, its own binary `vibe-acp`. `ask` asks before
// every tool; upstream removed its plan mode. No consent: Apache-2.0, on the
// user's own key (docs/acp-setup.md).
const _vibe = AcpProfile._(
  agent: AcpAgent.generic,
  pinned: [],
  caps: _asks,
  askMode: 'ask',
  signIn: 'Run `vibe-acp --setup` in a terminal, or set MISTRAL_API_KEY',
  keyEnv: ['MISTRAL_API_KEY'],
);

// Auggie (docs.augmentcode.com/cli/acp/agent): only `--acp` is documented;
// permissions and MCP aren't. No consent: Augment documents ACP for clients.
const _auggie = AcpProfile._(
  agent: AcpAgent.generic,
  pinned: [
    ['--acp'],
  ],
  extraEnv: {'AUGMENT_DISABLE_AUTO_UPDATE': '1'},
  caps: _asks,
  signIn: 'Run `auggie login` in a terminal',
  keyEnv: ['AUGMENT_SESSION_AUTH'],
);

// Factory Droid: the ACP registry's launch (docs.factory.ai describe
// `--output-format acp` for Zed and JetBrains). `--auto` and
// `--skip-permissions-unsafe` would raise its autonomy past asking. No
// consent: Factory documents ACP use from editors.
const _droid = AcpProfile._(
  agent: AcpAgent.generic,
  pinned: [
    ['exec'],
    ['--output-format', 'acp-daemon'],
  ],
  dropped: ['--skip-permissions-unsafe'],
  droppedWithValue: ['--auto'],
  extraEnv: {'DROID_DISABLE_AUTO_UPDATE': 'true', 'FACTORY_DROID_AUTO_UPDATE_ENABLED': 'false'},
  caps: _asks,
  signIn: 'Run `droid` in a terminal and sign in, or set FACTORY_API_KEY',
  keyEnv: ['FACTORY_API_KEY'],
);

// Cursor CLI (cursor.com/docs/cli/acp): `agent acp`, installed as both
// `cursor-agent` and `agent`; the unambiguous name is looked for first.
// Never its `ask` mode: that is read-only Q&A, while the app's Ask still
// edits after approval, so every app mode but Plan pins `agent` and Cursor's
// permission requests carry the approvals. Its question, plan, to-do and
// subagent requests are `cursor/*` extensions (`acp_cursor.dart`). Consent:
// Cursor documents ACP for custom clients, but its terms weren't read.
const _cursor = AcpProfile._(
  agent: AcpAgent.cursor,
  pinned: [
    ['acp'],
  ],
  // Its headless skip-approval flags, and the ones that trust the folder or
  // approve every MCP server unasked.
  dropped: ['--force', '--yolo', '-f', '--trust', '--approve-mcps'],
  caps: {..._shared, DriverCap.mcp, DriverCap.switchModel, DriverCap.subagents},
  askMode: 'agent',
  planMode: 'plan',
  signIn: 'Run `agent login` in a terminal',
  keyEnv: ['CURSOR_API_KEY', 'CURSOR_AUTH_TOKEN'],
  needsConsent: true,
  alsoNamed: ['cursor-agent', 'agent'],
);

// Grok Build (docs.x.ai/build/cli/reference lists `grok agent stdio`). The
// global flags go before `agent`, as in T3 Code (MIT),
// packages/provider-grok/src/server/acpSupport.ts `grokAcpSpawnArgs`:
// `--permission-mode default` keeps it asking whatever its config says, and
// `--no-auto-update` keeps the installed version (neither is in xAI's
// reference yet). `initialize` says `clientType: extension`, which asks
// instead of quietly refusing, and Stop is Ctrl+C, which also holds back
// background wakes until the next message. No session modes are known yet.
// No consent: xAI's announcement (x.ai/news/grok-build-cli) offers ACP
// "to build your own bots and agent orchestration apps".
const _grok = AcpProfile._(
  agent: AcpAgent.grok,
  pinned: [
    ['--permission-mode', 'default'],
    ['--no-auto-update'],
    ['agent'],
    ['stdio'],
  ],
  dropped: ['--always-approve', '--yolo', '--dangerously-skip-permissions'],
  // Allow rules (docs.x.ai/build/cli/reference) would let calls past the app.
  droppedWithValue: ['--allow'],
  caps: {..._shared, DriverCap.switchModel, DriverCap.subagents},
  signIn: 'Run `grok login` in a terminal',
  keyEnv: ['XAI_API_KEY'],
  ttyFallback: true,
  initializeMeta: {'clientType': 'extension'},
  cancelMeta: {'cancelTrigger': 'ctrl_c'},
);

/// `<name> version: v1.2.3`: how the same-named AWS Copilot CLI and pressly's
/// goose print their version, unlike the agents.
const _otherCli = r'^\S+ version: v\d';

const _generic = AcpProfile._(agent: AcpAgent.generic, pinned: [], caps: _shared, signIn: '');

/// The entry for [executable] (by its file name).
AcpProfile acpProfileOf(String executable) => switch (executable.split('/').last) {
  'gemini' => _gemini,
  'opencode' => _openCode,
  'agy' => _antigravity,
  'copilot' => _copilot,
  'kiro-cli' => _kiro,
  'kimi' => _kimi,
  'qwen' => _qwen,
  'cline' => _cline,
  'goose' => _goose,
  'vibe-acp' => _vibe,
  'auggie' => _auggie,
  'droid' => _droid,
  'cursor-agent' || 'agent' => _cursor,
  'grok' => _grok,
  _ => _generic,
};

/// What `acp:<command>` runs: [executable] (a name or a path) with [args].
typedef AcpCommand = ({String executable, List<String> args, AcpProfile profile});

/// [command] and [args] as the driver runs them. Without [args], a command
/// with spaces is split into words, one literal argument each, without a
/// shell (`acp:dsh --profile acp`). The profile's pinned arguments come first,
/// after [prefix] (a runner's own arguments: `npx -y <package>`). [profile]
/// replaces the one picked by the executable's name (an ACP registry agent
/// run through `npx` keeps its own).
AcpCommand acpCommand(String command, List<String> args, {AcpProfile? profile, List<String> prefix = const []}) {
  var exe = command.trim();
  var own = args;
  if (own.isEmpty && exe.contains(RegExp(r'\s'))) {
    final words = exe.split(RegExp(r'\s+'));
    exe = words.first;
    own = words.sublist(1);
  }
  final p = profile ?? acpProfileOf(exe);
  return (executable: exe, args: [...prefix, ..._pin(own, p)], profile: p);
}

/// ACP registry ids whose agent is listed here under another id.
const registryAliases = {'grok-build': 'grok'};

List<String> _pin(List<String> own, AcpProfile profile) {
  final flags = {for (final g in profile.pinned) g.first, ...profile.dropped, ...profile.droppedWithValue};
  final kept = <String>[];
  for (var i = 0; i < own.length; i++) {
    final a = own[i];
    final flag = flags.where((f) => a == f || a.startsWith('$f=')).firstOrNull;
    if (flag == null) {
      kept.add(a);
      continue;
    }
    // A pinned flag given without `=` takes as many values as the pinned one.
    // A dropped flag that takes a value loses it too.
    if (!a.contains('=')) {
      final group = profile.pinned.where((g) => g.first == flag).firstOrNull;
      i += group != null ? group.length - 1 : (profile.droppedWithValue.contains(flag) ? 1 : 0);
    }
  }
  return [for (final g in profile.pinned) ...g, ...kept];
}

/// [base] plus each flag group of [extra] whose flag isn't in [base] yet (the
/// Gemini recipe repeats `--acp`).
List<String> addArgs(List<String> base, List<String> extra) {
  final out = [...base];
  final groups = <List<String>>[];
  for (final a in extra) {
    if (groups.isEmpty || a.startsWith('-')) {
      groups.add([a]);
    } else {
      groups.last.add(a);
    }
  }
  for (final g in groups) {
    if (!out.contains(g.first)) out.addAll(g);
  }
  return out;
}

/// OpenCode's permission rules for a session: every tool asks, so commands,
/// edits, fetches and MCP calls reach the app's approvals; its to-do list,
/// subagents and skills run without asking (their own tool calls still ask).
const openCodePermissions = {'*': 'ask', 'todowrite': 'allow', 'todoread': 'allow', 'task': 'allow', 'skill': 'allow'};

/// The agents [openCodePermissions] are pinned on as well. OpenCode applies
/// the last matching rule, and puts every config's agent rules after all the
/// top-level ones (2.1.3), so an `agent.build.permission` in the user's
/// config would otherwise win over ours.
const openCodeAgents = ['build', 'plan', 'general', 'explore'];

/// [env] with [openCodePermissions] merged into `OPENCODE_CONFIG_CONTENT`
/// (top level and per agent), and the project's own OpenCode config turned
/// off: a cloned repository's `opencode.json` or `.opencode/` could allow
/// tools, define agents or run plugins, and the app takes no settings from
/// repository files.
Map<String, String> withOpenCodePermissions(Map<String, String> env) {
  final config = <String, Object?>{};
  if (env['OPENCODE_CONFIG_CONTENT'] case final s?) {
    if (jsonDecode(s) case final Map<String, Object?> m) config.addAll(m);
  }
  config['permission'] = openCodePermissions;
  final agents = <String, Object?>{...?(config['agent'] as Map<String, Object?>?)};
  for (final a in openCodeAgents) {
    agents[a] = {...?(agents[a] as Map<String, Object?>?), 'permission': openCodePermissions};
  }
  config['agent'] = agents;
  return {...env, 'OPENCODE_CONFIG_CONTENT': jsonEncode(config), 'OPENCODE_DISABLE_PROJECT_CONFIG': '1'};
}
