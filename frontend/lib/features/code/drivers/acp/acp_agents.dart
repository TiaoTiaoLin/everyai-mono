// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../briefing/briefing_types.dart';
import '../briefing/recipes.dart' as recipes;
import '../driver.dart';
import 'acp_files.dart';

// What the app knows about each ACP agent it drives. One generic client
// serves them all; an entry exists only where an agent would otherwise get
// past the app's approvals (Gemini can start in its yolo mode, OpenCode never
// asks by default) or needs its own sign-in check.

/// The agents with an entry of their own; anything else is [generic].
enum AcpAgent { gemini, openCode, generic }

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
    this.askMode,
    this.planMode,
  });

  final AcpAgent agent;

  /// Arguments it always runs with, as flag groups (a flag and its values, or
  /// a subcommand). One replaces the same flag given in the command.
  final List<List<String>> pinned;

  /// Flags removed from the command (they would skip the agent's prompts).
  final List<String> dropped;
  final Set<DriverCap> caps;

  /// The agent's own mode that asks before acting, set for every app mode
  /// but Plan; null leaves its modes alone.
  final String? askMode;

  /// Its read-only mode, for Plan (when it has one).
  final String? planMode;

  /// What the user does to sign in, as an instruction.
  final String signIn;

  /// How the session's briefing reaches it (`drivers/briefing/recipes.dart`).
  Delivery deliver(BriefingInput i, List<({String name, String description})> skills) => switch (agent) {
    AcpAgent.gemini => recipes.gemini(i, skills: skills),
    AcpAgent.openCode => recipes.openCode(i),
    AcpAgent.generic => recipes.acp(i, skills: skills),
  };

  /// Its environment on top of [delivery]'s: OpenCode gets [openCodePermissions].
  Map<String, String> env(Delivery? delivery) => switch (agent) {
    AcpAgent.openCode => withOpenCodePermissions(delivery?.env ?? const {}),
    _ => delivery?.env ?? const {},
  };

  /// Whether the session's MCP server goes in the agent's config ([env])
  /// rather than in `session/new`.
  bool get mcpInConfig => agent == AcpAgent.openCode;

  /// Whether it is signed in, without a model call; null when it can't tell.
  Future<bool?> signedIn(String executable) => switch (agent) {
    AcpAgent.gemini => geminiSignedIn(),
    AcpAgent.openCode => openCodeSignedIn(executable),
    AcpAgent.generic => Future.value(),
  };
}

const _shared = {DriverCap.resume, DriverCap.approvals, DriverCap.perCallApprovals};

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
  signIn: 'Run `gemini` in a terminal and sign in',
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

const _generic = AcpProfile._(agent: AcpAgent.generic, pinned: [], caps: _shared, signIn: '');

/// The entry for [executable] (by its file name).
AcpProfile acpProfileOf(String executable) => switch (executable.split('/').last) {
  'gemini' => _gemini,
  'opencode' => _openCode,
  _ => _generic,
};

/// What `acp:<command>` runs: [executable] (a name or a path) with [args].
typedef AcpCommand = ({String executable, List<String> args, AcpProfile profile});

/// [command] and [args] as the driver runs them. Without [args], a command
/// with spaces is split into words, one literal argument each, without a
/// shell (`acp:dsh --profile acp`). The profile's pinned arguments come first.
AcpCommand acpCommand(String command, List<String> args) {
  var exe = command.trim();
  var own = args;
  if (own.isEmpty && exe.contains(RegExp(r'\s'))) {
    final words = exe.split(RegExp(r'\s+'));
    exe = words.first;
    own = words.sublist(1);
  }
  final profile = acpProfileOf(exe);
  return (executable: exe, args: _pin(own, profile), profile: profile);
}

List<String> _pin(List<String> own, AcpProfile profile) {
  final flags = {for (final g in profile.pinned) g.first, ...profile.dropped};
  final kept = <String>[];
  for (var i = 0; i < own.length; i++) {
    final a = own[i];
    final flag = flags.where((f) => a == f || a.startsWith('$f=')).firstOrNull;
    if (flag == null) {
      kept.add(a);
      continue;
    }
    // A pinned flag given without `=` takes as many values as the pinned one.
    if (!a.contains('=')) {
      final group = profile.pinned.where((g) => g.first == flag).firstOrNull;
      i += (group?.length ?? 1) - 1;
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
/// Inline config outranks the project's and the user's.
const openCodePermissions = {'*': 'ask', 'todowrite': 'allow', 'todoread': 'allow', 'task': 'allow', 'skill': 'allow'};

/// [env] with [openCodePermissions] merged into `OPENCODE_CONFIG_CONTENT`.
Map<String, String> withOpenCodePermissions(Map<String, String> env) {
  final config = <String, Object?>{};
  if (env['OPENCODE_CONFIG_CONTENT'] case final s?) {
    if (jsonDecode(s) case final Map<String, Object?> m) config.addAll(m);
  }
  config['permission'] = openCodePermissions;
  return {...env, 'OPENCODE_CONFIG_CONTENT': jsonEncode(config)};
}
