// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../drivers/driver_policy.dart' show hostToolOf, trustedHostTools;
import '../harness/events.dart';
import 'agent_mode.dart';
import 'shell_readonly.dart';

/// The app's command policy for Code sessions. The agent server confirms
/// every action (see [AgentMode.confirmationPolicy]); the app then decides,
/// in this order:
///
/// 1. client tools (question cards, plans) go to their own UI;
/// 2. the hardline floor ([floorReason]) blocks a short list of
///    catastrophic commands in every mode, Full auto included;
/// 3. the user's `deny` rules block what they match;
/// 4. Plan mode refuses anything that isn't read-only;
/// 5. read-only actions run, and so do writes to scratch space
///    ([isScratchWrite]: the project's `.everyai/scratch/` and the OS temp
///    folders);
/// 6. dangerous actions ([dangerReason], [editDangerReason]) always ask,
///    except in Full auto;
/// 7. `allow` rules and approvals remembered for the session run, but only
///    for simple commands (one command, nothing chained);
/// 8. otherwise the mode decides.
///
/// Like any check on a shell string this is defence in depth, not a
/// sandbox: the agent runs as the user, in the session's worktree.
enum Verdict { allow, ask, deny }

/// Which step of the policy decided.
enum DecisionSource { clientTool, floor, rule, plan, readOnly, scratch, dangerous, allowRule, mode }

@immutable
final class Decision {
  const Decision(this.verdict, this.source, {this.why = '', this.rule});

  final Verdict verdict;
  final DecisionSource source;

  /// For the floor and dangerous actions: what the action does, in a few words.
  final String why;

  /// The permission rule that matched.
  final String? rule;

  @override
  String toString() => 'Decision($verdict, $source${why.isEmpty ? '' : ', $why'}${rule == null ? '' : ', $rule'})';
}

/// User permission rules. A rule is a glob on a command (`npm test *`, also
/// written `Bash(npm test *)`) or on a path relative to the project:
/// `Edit(src/**)`, `Read(.env*)`. In globs `*` matches anything (within a
/// path segment for paths), `**` crosses folders, `?` one character, and a
/// trailing ` *` also matches the bare command. A path glob without a `/`
/// matches the file name in any folder. `Mcp(…)` globs an MCP tool's name.
@immutable
final class PermissionRules {
  const PermissionRules({this.allow = const [], this.deny = const []});

  static const none = PermissionRules();

  final List<String> allow;
  final List<String> deny;

  bool get isEmpty => allow.isEmpty && deny.isEmpty;

  PermissionRules operator +(PermissionRules o) =>
      PermissionRules(allow: _union(allow, o.allow), deny: _union(deny, o.deny));

  static List<String> _union(List<String> a, List<String> b) => [
    ...a,
    for (final r in b)
      if (!a.contains(r)) r,
  ];

  factory PermissionRules.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return none;
    List<String> strings(Object? v) => [
      if (v is List<Object?>)
        for (final s in v)
          if (s is String && s.trim().isNotEmpty) s.trim(),
    ];
    return PermissionRules(allow: strings(json['allow']), deny: strings(json['deny']));
  }

  Map<String, Object?> toJson() => {'allow': allow, 'deny': deny};
}

/// Outside harnesses' own calls that end their plan mode with a plan for the
/// user to approve (Claude Code's `ExitPlanMode`). Plan mode asks about them
/// instead of refusing, or the harness could never leave plan.
const planExitTools = {'ExitPlanMode'};

/// Decides what happens to the agent's actions in one session.
@immutable
final class PermissionPolicy {
  const PermissionPolicy({
    this.rules = PermissionRules.none,
    this.session = const {},
    this.workingDir,
    this.hostTools = false,
    this.tempDirs = const [],
    this.isLink,
  });

  /// Whether a path on disk is a symlink (see temp_dirs_io.dart), or null to
  /// not look: scratch writes through a link don't count as scratch.
  final bool Function(String path)? isLink;

  /// The OS temp folders (see temp_dirs_io.dart), where writes never ask
  /// outside Plan mode, like the project's `.everyai/scratch/`.
  final List<String> tempDirs;

  /// The session runs on an outside agent, whose MCP calls to the app's own
  /// host ([trustedHostTools]) run without asking: they only show a card or
  /// keep the project's notes. Off for the EveryAI harness, where an MCP
  /// server called "everyai" is the user's own.
  final bool hostTools;

  /// Settings and stored rules (global, then project).
  final PermissionRules rules;

  /// Patterns the user approved "for this session" (see [rememberPattern]).
  final Set<String> session;

  /// The session's folder; paths in rules are relative to it.
  final String? workingDir;

  /// [floor]: false skips the safety floor, so an outside harness can see
  /// what the rest of the policy says about a floor hit (see floor_advice.dart).
  Decision decide(ActionCall call, AgentMode mode, {bool floor = true}) {
    if (isClientTool(call)) return const Decision(Verdict.allow, DecisionSource.clientTool);
    // Bypass: the user turned every EveryAI check off (floor, rules, risk) for this session.
    if (mode == AgentMode.bypass) return const Decision(Verdict.allow, DecisionSource.mode);
    final command = _command(call);
    // Keys typed into a running shell are checked like a command.
    if (floor ? command ?? _typed(call) : null case final text?) {
      if (floorReason(text) case final why?) return Decision(Verdict.deny, DecisionSource.floor, why: why);
    }
    if (_matching(call, rules.deny, allowing: false) case final rule?) {
      return Decision(Verdict.deny, DecisionSource.rule, rule: rule);
    }
    if (hostTools && trustedHostTools.contains(hostToolOf(call))) {
      return const Decision(Verdict.allow, DecisionSource.clientTool);
    }
    // MCP tools: never read-only; an allow rule or Full auto runs them, and
    // every other mode (Plan included) asks.
    if (isMcpTool(call)) {
      if (_matching(call, [...rules.allow, ...session], allowing: true) case final rule?) {
        return Decision(Verdict.allow, DecisionSource.allowRule, rule: rule);
      }
      return Decision(mode == AgentMode.fullAuto ? Verdict.allow : Verdict.ask, DecisionSource.mode);
    }
    // A bug_check without a command records a step, or re-runs the repro already approved.
    if (call.toolName == 'bug_check' && command == null) return const Decision(Verdict.allow, DecisionSource.readOnly);
    final readOnly = AgentMode.isReadOnly(call);
    // Plan mode refuses changes; looking things up (gh reads, git fetch, curl to stdout) asks like Ask mode.
    final lookup = command != null && call.action['is_input'] != true && isPlanningShell(command);
    // Leaving plan with a plan (Claude's ExitPlanMode) is the user's call, as present_plan is.
    if (mode == AgentMode.plan && planExitTools.contains(call.toolName)) {
      return const Decision(Verdict.ask, DecisionSource.mode);
    }
    if (mode == AgentMode.plan && !readOnly && !lookup) return const Decision(Verdict.deny, DecisionSource.plan);
    if (readOnly) return const Decision(Verdict.allow, DecisionSource.readOnly);
    final edits = _editPaths(call);
    // Scratch space is the agent's own: writes there (and making folders there) never ask.
    bool scratch(String p) => isScratchWrite(p, workingDir: workingDir, tempDirs: tempDirs, isLink: isLink);
    if (edits.isNotEmpty ? edits.every(scratch) : command != null && _mkdirsOnly(command, scratch)) {
      return const Decision(Verdict.allow, DecisionSource.scratch);
    }
    final danger = command != null
        ? dangerReason(command)
        : [for (final e in edits) ?editDangerReason(e, workingDir: workingDir)].firstOrNull;
    // Full auto never asks. Elsewhere a risky action asks once: Allow saves it as a rule without wildcards (the exact
    // command, the file, the folder outside the project), which settles it from then on.
    if (danger != null && mode != AgentMode.fullAuto) {
      if (_matching(call, [...rules.allow, ...session].where(_pinned).toList(), allowing: true) case final rule?) {
        return Decision(Verdict.allow, DecisionSource.allowRule, rule: rule);
      }
      return Decision(Verdict.ask, DecisionSource.dangerous, why: danger);
    }
    if (danger == null) {
      if (_matching(call, [...rules.allow, ...session], allowing: true) case final rule?) {
        return Decision(Verdict.allow, DecisionSource.allowRule, rule: rule);
      }
    }
    final allowed = switch (mode) {
      AgentMode.fullAuto || AgentMode.bypass => true,
      AgentMode.autoEdit => edits.isNotEmpty,
      AgentMode.ask || AgentMode.plan => false,
    };
    return Decision(allowed ? Verdict.allow : Verdict.ask, DecisionSource.mode, why: danger ?? '');
  }

  /// One answer for everything the server is waiting on (it approves or
  /// rejects all pending actions at once): a refusal with the text the
  /// agent reads, approval, or null to ask the user.
  /// [askMcp]: MCP tools that only the mode (Full auto) would run go to the
  /// user instead; a Max/Ultra flow sets it before the plan is approved,
  /// since an MCP tool may change things outside the files it gates.
  ({bool accept, String? reason})? decideAll(List<ActionCall> calls, AgentMode mode, {bool askMcp = false}) {
    if (calls.isEmpty) return null;
    final decisions = [for (final c in calls) (c, decide(c, mode))];
    final blocked = [
      for (final (c, d) in decisions)
        if (d.source == DecisionSource.floor || d.source == DecisionSource.rule) (c, d),
    ];
    if (blocked.isNotEmpty) return (accept: false, reason: policyDenial(blocked, batch: calls.length));
    if (decisions.any((e) => e.$2.source == DecisionSource.plan)) {
      return (accept: false, reason: AgentMode.planRefusal);
    }
    if (askMcp &&
        mode != AgentMode.bypass &&
        mode != AgentMode.fullAuto &&
        decisions.any((e) => isMcpTool(e.$1) && e.$2.source == DecisionSource.mode)) {
      return null;
    }
    if (decisions.every((e) => e.$2.verdict == Verdict.allow)) return (accept: true, reason: null);
    return null;
  }

  /// The first rule in [patterns] that matches [call]. Allow rules only
  /// match a simple command: a chain (`a && b`, pipes, `;`) or anything the
  /// parser can't vouch for is never approved by a rule. Deny rules also
  /// match keys typed into a running process, and `Read(…)`/`Edit(…)` deny
  /// rules match terminal commands by their path arguments (see
  /// [_commandReads], [_commandWrites]).
  String? _matching(ActionCall call, List<String> patterns, {required bool allowing}) {
    if (patterns.isEmpty) return null;
    final command = _command(call) ?? (allowing ? null : _typed(call));
    final edits = _editPaths(call);
    final read = _readPath(call);
    for (final raw in patterns) {
      final rule = _Rule.parse(raw);
      if (rule == null) continue;
      final hit = switch (rule.kind) {
        _RuleKind.command when command != null =>
          allowing ? _allowsCommand(rule.glob, command) : _deniesCommand(rule.glob, command),
        // A patch is allowed only when the rule covers every file it writes, and denied when it covers any.
        _RuleKind.edit when edits.isNotEmpty =>
          allowing ? edits.every((e) => _covers(rule.glob, e)) : edits.any((e) => _covers(rule.glob, e)),
        _RuleKind.read when read != null => _covers(rule.glob, read),
        _RuleKind.read when !allowing && command != null => _commandReads(command).any((p) => _covers(rule.glob, p)),
        _RuleKind.mcp => isMcpTool(call) && globMatches(rule.glob, call.toolName),
        _RuleKind.exact when allowing && command != null => _collapse(command) == _collapse(rule.glob),
        _RuleKind.tool when allowing => _ownTool(call) && call.toolName == rule.glob,
        _RuleKind.edit when !allowing && command != null => _commandWrites(command).any((p) => _covers(rule.glob, p)),
        _ => false,
      };
      if (hit) return raw;
    }
    // A chain (`cd app && npm test | tail`) is allowed when every simple command in it is: each part matched by a
    // command rule. Anything the parser can't vouch for (`$(…)`, subshells, heredocs) still asks.
    if (allowing && command != null) {
      final segments = shellSegments(command);
      if (segments != null && segments.length > 1) {
        final rules = [
          for (final raw in patterns)
            if (_Rule.parse(raw) case final r? when r.kind == _RuleKind.command) (raw, r.glob),
        ];
        final used = <String>[];
        for (final seg in segments) {
          final words = seg.join(' ');
          final hit = rules.where((r) => globMatches(r.$2, words)).firstOrNull;
          if (hit == null) return null;
          if (!used.contains(hit.$1)) used.add(hit.$1);
        }
        return used.join(', ');
      }
    }
    return null;
  }

  String _relative(String path) => relativeTo(path, workingDir);

  /// Whether a path rule's [glob] covers [path]: matched against the path relative to the project and against the
  /// absolute path (rules may name either), and a rule naming a folder without wildcards (`src`, `/home/me/app/`)
  /// covers everything in it.
  bool _covers(String glob, String path) {
    final dir = workingDir;
    final abs = path.startsWith('/') || dir == null || dir.isEmpty ? path : '${dir.endsWith('/') ? dir : '$dir/'}$path';
    for (final target in {_relative(path), abs}) {
      if (_pathMatches(glob, target)) return true;
      if (!glob.contains(RegExp(r'[*?\[]'))) {
        final folder = glob.length > 1 && glob.endsWith('/') ? glob.substring(0, glob.length - 1) : glob;
        if (folder.isNotEmpty && (target == folder || target.startsWith('$folder/'))) return true;
      }
    }
    return false;
  }
}

/// A rule with no wildcards: the only kind that settles a risky action (see [PermissionPolicy.decide]).
bool _pinned(String raw) {
  final r = _Rule.parse(raw);
  if (r == null || r.kind == _RuleKind.mcp) return false;
  return r.kind == _RuleKind.exact || r.kind == _RuleKind.tool || !r.glob.contains(RegExp(r'[*?\[]'));
}

/// A call none of the command, path or MCP rules can judge: an outside lead's own tool.
bool _ownTool(ActionCall call) =>
    _command(call) == null && _editPaths(call).isEmpty && _readPath(call) == null && !isMcpTool(call);

/// [path] relative to [dir] when it is inside it, else unchanged.
String relativeTo(String path, String? dir) {
  if (dir == null || dir.isEmpty) return path;
  final base = dir.endsWith('/') ? dir : '$dir/';
  return path.startsWith(base) ? path.substring(base.length) : path;
}

/// The shell command of a terminal action (not keystrokes to a running process).
String? _command(ActionCall call) => call.actionKind == 'TerminalAction' && call.action['is_input'] != true
    ? call.str('command')
    // Bug fix mode's repro runs a command too (the host's for an outside agent), checked the same way.
    : (call.toolName == 'bug_check' || hostToolOf(call) == 'bug_check') && call.str('command').isNotEmpty
    ? call.str('command')
    : null;

/// Keys sent to a running process (`is_input`), which may be a shell.
String? _typed(ActionCall call) =>
    call.actionKind == 'TerminalAction' && call.action['is_input'] == true ? call.str('command') : null;

/// Arguments of [command] that may name files: every word after the program
/// in every part, redirect targets included, `--flag=value` values, with
/// `./` dropped. A best effort: globs (`cat .e*`) and recursive searches
/// (`grep -r KEY .`) are not expanded.
List<String> commandPaths(String command) {
  final out = <String>[];
  for (final part in commandParts(command)) {
    // Redirects become word breaks: `echo x>out` names `out`.
    final words = _words(_collapse(part.replaceAll(RegExp(r'\d*&?[<>]+&?'), ' ')));
    for (var w in words.skip(1)) {
      if (w.startsWith('-')) {
        final eq = w.indexOf('=');
        if (eq < 0) continue;
        w = w.substring(eq + 1);
      }
      while (w.startsWith('./')) {
        w = w.substring(2);
      }
      if (w.isEmpty || w.contains('://') || RegExp(r'^\d+$').hasMatch(w)) continue;
      out.add(w);
    }
  }
  return out;
}

/// Files a terminal command may read: any path argument.
List<String> _commandReads(String command) => commandPaths(command);

/// Files a terminal command may change: any path argument of a command that
/// isn't read-only.
List<String> _commandWrites(String command) => isReadOnlyShell(command) ? const [] : commandPaths(command);

/// The file a write would change.
String? _editPath(ActionCall call) => switch (call.actionKind) {
  'FileEditorAction' when call.str('command') != 'view' => call.str('path'),
  'EditAction' || 'WriteFileAction' => call.str('path'),
  // A patch to one file is an edit of it; to several, see [_editPaths].
  'ApplyPatchAction' => switch (_patchPaths(call)) {
    [final only] => only,
    _ => null,
  },
  _ => null,
};

/// Every file a write would change (a patch can change several).
List<String> _editPaths(ActionCall call) =>
    call.actionKind == 'ApplyPatchAction' ? _patchPaths(call) : [?_editPath(call)];

List<String> _patchPaths(ActionCall call) => [
  for (final p in call.action['paths'] as List<Object?>? ?? const [])
    if (p is String && p.isNotEmpty) p,
];

String? _readPath(ActionCall call) => switch (call.actionKind) {
  'FileEditorAction' when call.str('command') == 'view' => call.str('path'),
  'ReadFileAction' => call.str('path'),
  _ => null,
};

enum _RuleKind { command, edit, read, mcp, exact, tool }

final class _Rule {
  const _Rule(this.kind, this.glob);
  final _RuleKind kind;
  final String glob;

  static final _wrapped = RegExp(r'^(\w+)\((.*)\)$', dotAll: true);

  static _Rule? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final m = _wrapped.firstMatch(s);
    if (m == null) return _Rule(_RuleKind.command, s);
    final glob = m.group(2)!.trim();
    if (glob.isEmpty) return null;
    return switch (m.group(1)!.toLowerCase()) {
      'bash' || 'shell' || 'command' => _Rule(_RuleKind.command, glob),
      'edit' || 'write' => _Rule(_RuleKind.edit, glob),
      'read' => _Rule(_RuleKind.read, glob),
      // A glob on an MCP tool's name: `Mcp(browser_take_screenshot)`, `Mcp(playwright_*)`.
      'mcp' => _Rule(_RuleKind.mcp, glob),
      // One whole command, word for word (how a risky command is remembered).
      'exact' => _Rule(_RuleKind.exact, glob),
      // An outside lead's own tool by name (`Tool(WebFetch)`), for kinds the other rules can't judge.
      'tool' => _Rule(_RuleKind.tool, glob),
      _ => null,
    };
  }
}

/// Whether [glob] matches [text]. Command globs let `*` cross anything;
/// path globs keep `*` inside one folder.
bool globMatches(String glob, String text, {bool path = false}) {
  final b = StringBuffer('^');
  var i = 0;
  var g = glob;
  var optionalTail = false;
  if (!path && g.endsWith(' *')) {
    g = g.substring(0, g.length - 2);
    optionalTail = true;
  }
  while (i < g.length) {
    final c = g[i];
    if (c == '*') {
      if (i + 1 < g.length && g[i + 1] == '*') {
        // `**/` also matches no folder at all.
        if (path && i + 2 < g.length && g[i + 2] == '/') {
          b.write('(?:.*/)?');
          i += 3;
        } else {
          b.write('.*');
          i += 2;
        }
        continue;
      }
      b.write(path ? '[^/]*' : '.*');
    } else if (c == '?') {
      b.write(path ? '[^/]' : '.');
    } else {
      b.write(RegExp.escape(c));
    }
    i++;
  }
  if (optionalTail) b.write('(?: .*)?');
  b.write(r'$');
  return RegExp(b.toString(), dotAll: true).hasMatch(text);
}

bool _pathMatches(String glob, String path) {
  if (globMatches(glob, path, path: true)) return true;
  // `.env` matches the name in any folder, the way .gitignore does.
  if (!glob.contains('/')) return globMatches(glob, path.split('/').last, path: true);
  return false;
}

/// Deny rules match any part of the command, wherever it hides (chains,
/// `$(…)`, `sh -c "…"`), or the command as a whole.
bool _deniesCommand(String glob, String command) {
  final whole = _collapse(_unquote(command));
  if (globMatches(glob, whole)) return true;
  return commandParts(command).any((p) => globMatches(glob, p));
}

/// Allow rules match only a simple command, every word as the parser reads it.
bool _allowsCommand(String glob, String command) {
  final segments = shellSegments(command);
  if (segments == null || segments.length != 1) return false;
  return globMatches(glob, segments.single.join(' '));
}

// ---------------------------------------------------------------------------
// Splitting commands for the floor, the classifier and deny rules.

/// Every simple command inside [raw], normalized for matching: quotes
/// removed, spaces collapsed, and wrappers that only change how the command
/// runs (`sudo`, `env X=1`, `nohup`, `timeout 5`, `/bin/`) stripped off the
/// front. Unlike [shellSegments] this never gives up: it also looks inside
/// `$(…)`, backticks and `sh -c "…"`/`eval` arguments.
List<String> commandParts(String raw) => [for (final p in _parts(raw, 0)) p.text];

/// One simple command found by [_parts].
final class _Part {
  const _Part(this.text, {this.viaXargs = false, this.input});

  /// Normalized (see [commandParts]).
  final String text;

  /// Whether `xargs` runs it, so its arguments also come from [input].
  final bool viaXargs;

  /// The command piped into it (`a | b` gives `a` for `b`), normalized.
  final String? input;
}

List<_Part> _parts(String raw, int depth) {
  final pieces = <(String, bool)>[];
  final b = StringBuffer();
  String? quote;
  var piped = false;
  void flush({bool pipe = false}) {
    final t = b.toString().trim();
    if (t.isNotEmpty) pieces.add((t, piped));
    piped = pipe && t.isNotEmpty;
    b.clear();
  }

  for (var i = 0; i < raw.length; i++) {
    final c = raw[i];
    if (quote == "'") {
      if (c == "'") quote = null;
      b.write(c);
      continue;
    }
    if (c == r'\' && i + 1 < raw.length) {
      b
        ..write(c)
        ..write(raw[i + 1]);
      i++;
      continue;
    }
    // Command substitution starts a new command, even inside double quotes.
    if (c == '`' || (c == r'$' && i + 1 < raw.length && raw[i + 1] == '(')) {
      flush();
      quote = null;
      if (c == r'$') i++;
      continue;
    }
    if (quote == '"') {
      if (c == '"') quote = null;
      b.write(c);
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      b.write(c);
      continue;
    }
    if (';&|\n()'.contains(c)) {
      // A single `|` (not `||`, not `|&`) pipes into the next command.
      final pipe =
          c == '|' &&
          (i + 1 >= raw.length || (raw[i + 1] != '|' && raw[i + 1] != '&')) &&
          (i == 0 || raw[i - 1] != '|');
      flush(pipe: pipe);
      continue;
    }
    b.write(c);
  }
  flush();
  final out = <_Part>[];
  String? previous;
  for (final (p, pipedIn) in pieces) {
    final (stripped, xargs) = _stripWrappers(p);
    // Escapes and quotes removed, wrappers that only showed up then stripped too.
    final (normalized, xargs2) = _stripWrappers(_collapse(_unescape(_unquote(stripped))));
    if (normalized.isNotEmpty) {
      out.add(_Part(normalized, viaXargs: xargs || xargs2, input: pipedIn ? previous : null));
    }
    previous = normalized;
    if (depth < 3) {
      if (_innerScript(stripped) case final inner?) out.addAll(_parts(inner, depth + 1));
    }
  }
  return out;
}

/// A wrapper program and its options. Options in [valued] (one letter) and
/// [long] take a value, which is skipped too: `nice -n 10 rm` is `rm`.
RegExp _wrapper(String names, {String valued = '', String long = '', String after = ''}) => RegExp(
  '^($names)'
  r'(\s+('
  '${valued.isEmpty ? '' : r'-[' + valued + r']\s+\S+|'}'
  '${long.isEmpty ? '' : r'--(' + long + r')\s+\S+|'}'
  r'-\S+))*\s+'
  '$after',
);

final _wrappers = [
  RegExp(r'^\\'),
  RegExp(
    r'^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'
    "'[^']*'"
    r'|\S*)\s+',
  ),
  _wrapper(
    'sudo',
    valued: 'ugCDhpRrTtU',
    long: 'user|group|close-from|chdir|host|prompt|chroot|role|type|command-timeout|other-user',
  ),
  _wrapper('doas', valued: 'uC'),
  _wrapper('nice', valued: 'n', long: 'adjustment'),
  _wrapper('time', valued: 'fo', long: 'format|output'),
  _wrapper('exec', valued: 'a'),
  _wrapper('caffeinate', valued: 'tw'),
  _wrapper('stdbuf', valued: 'ioe', long: 'input|output|error'),
  _wrapper('ionice', valued: 'cnp', long: 'class|classdata|pid'),
  _wrapper('command|builtin|nohup'),
  // `-S` is left alone: its value is the command (`env -S 'rm -rf ~'`).
  RegExp(r'^env(\s+(-[uCP]\s+\S+|--(unset|chdir)\s+\S+|-\S+)|\s+[A-Za-z_][A-Za-z0-9_]*=\S*)*\s+'),
  _wrapper('timeout|gtimeout', valued: 'sk', long: 'signal|kill-after', after: r'\S+\s+'),
  RegExp(r'^/(?:[\w.+-]+/)+(?=[\w.+-]+(\s|$))'),
];

final _xargs = _wrapper(
  'xargs',
  valued: 'IdLnPsEJRSa',
  long: 'max-args|max-lines|replace|delimiter|max-procs|arg-file|eof|max-chars',
);

/// [s] without the wrappers in front, and whether one was `xargs`.
(String, bool) _stripWrappers(String s) {
  var out = s.trim();
  var xargs = false;
  for (var changed = true; changed;) {
    changed = false;
    for (final w in [..._wrappers, _xargs]) {
      final next = out.replaceFirst(w, '');
      if (next != out) {
        out = next.trimLeft();
        changed = true;
        if (identical(w, _xargs)) xargs = true;
      }
    }
  }
  return (out, xargs);
}

String _unquote(String s) => s.replaceAll(RegExp(r'''["']'''), '');

/// Backslash escapes removed: `r\m` runs `rm`.
String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);

/// Words a part should not start with after its wrappers are stripped: an
/// option, a number (`nice -n 10 …` misread), or a wrapper left over.
bool _unparsed(String first) =>
    first.startsWith('-') ||
    RegExp(r'^\d+$').hasMatch(first) ||
    const {
      'sudo', 'doas', 'env', 'nice', 'time', 'exec', 'caffeinate', 'stdbuf', 'ionice', 'command', 'builtin', //
      'nohup', 'timeout', 'gtimeout', 'xargs',
    }.contains(first);

String _collapse(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

final _shellC = RegExp(r'^(?:\S*/)?(?:ba|z|da|k|fi)?sh\s+(?:-\w+\s+)*-\w*c\s+(?:-\S*\s+)*(.+)$', dotAll: true);
final _evalArg = RegExp(r'^eval\s+(.+)$', dotAll: true);

/// The script `sh -c '…'` or `eval '…'` runs, quotes removed.
String? _innerScript(String s) {
  final m = _shellC.firstMatch(s) ?? _evalArg.firstMatch(s);
  if (m == null) return null;
  var arg = m.group(1)!.trim();
  if (arg.length >= 2 && (arg[0] == "'" || arg[0] == '"')) {
    final end = arg.lastIndexOf(arg[0]);
    if (end > 0) arg = arg.substring(1, end);
  }
  return arg;
}

List<String> _words(String part) => part.split(' ');

bool _recursive(List<String> args, {bool lowerR = true}) => args.any(
  (a) =>
      a == '--recursive' ||
      (!a.startsWith('--') && RegExp(lowerR ? r'^-[a-zA-Z]*[rR][a-zA-Z]*$' : r'^-[a-zA-Z]*R[a-zA-Z]*$').hasMatch(a)),
);

final _systemDir = RegExp(
  r'^/(Users|home|root|etc|usr|bin|sbin|lib|lib64|var|System|Library|Applications|opt|private|boot|dev|Volumes|'
  r'proc|sys|cores|nix)(/\*)?$',
);
final _homeDir = RegExp(r'^/(Users|home)/[^/*]+(/\*)?$');

/// The file system root, a home folder, or a system folder.
bool _isRootTarget(String arg) {
  var t = arg;
  while (t.length > 1 && t.endsWith('/')) {
    t = t.substring(0, t.length - 1);
  }
  if (t == '//' || t == '/.') t = '/';
  const exact = {'/', '/*', '~', '~/*', r'$HOME', r'${HOME}', r'$HOME/*', r'${HOME}/*', '~/.', '/..'};
  return exact.contains(t) || _systemDir.hasMatch(t) || _homeDir.hasMatch(t);
}

/// `git` with its global options skipped: the subcommand and what follows.
(String, List<String>)? _git(List<String> w) {
  if (w.isEmpty || w.first != 'git') return null;
  var i = 1;
  while (i < w.length && w[i].startsWith('-')) {
    i += const {'-C', '-c', '--git-dir', '--work-tree', '--namespace'}.contains(w[i]) ? 2 : 1;
  }
  if (i >= w.length) return null;
  return (w[i], w.sublist(i + 1));
}

bool _shortFlag(List<String> args, String letter) =>
    args.any((a) => !a.startsWith('--') && RegExp('^-[a-zA-Z]*$letter[a-zA-Z]*\$').hasMatch(a));

bool _hasFlag(List<String> args, Set<String> flags) => args.any((a) => flags.any((f) => a == f || a.startsWith('$f=')));

/// A git push that overwrites or deletes remote history.
({bool force, bool delete, bool mirror, bool main})? _push(List<String> w) {
  final git = _git(w);
  if (git == null || git.$1 != 'push') return null;
  final args = git.$2;
  final positionals = args.where((a) => !a.startsWith('-')).toList();
  final force =
      _hasFlag(args, {'--force', '--force-with-lease'}) ||
      _shortFlag(args, 'f') ||
      positionals.any((p) => p.startsWith('+'));
  final delete =
      _hasFlag(args, {'--delete', '--prune'}) || _shortFlag(args, 'd') || positionals.any((p) => p.startsWith(':'));
  final main = positionals.skip(1).any((p) => RegExp(r'(^|[:/+])(main|master)$').hasMatch(p));
  return (force: force, delete: delete, mirror: args.contains('--mirror'), main: main);
}

final _forkBomb = RegExp(r'(\w+|:)\(\)\{\1\|\1&\};?\1');
final _diskDevice = RegExp(r'/dev/(r?disk\d|sd[a-z]|nvme\d|hd[a-z]|mmcblk\d|xvd[a-z]|vd[a-z])');
final _toRootShell = RegExp(
  r'\b(curl|wget|fetch)\b[^|;&]*\|\s*(sudo|doas)\s+(-\S+\s+)*(\S*/)?(ba|z|da|k|fi)?sh\b|'
  r'''\b(sudo|doas)\s+(\S*/)?(ba|z|da|k)?sh\s+-c\s+["']?\$\(\s*(curl|wget)''',
);

/// Why [command] is never run, in any mode, or null. The list is short on
/// purpose: things no coding task needs and nobody can undo (wiping the
/// disk or home folder, formatting, fork bombs, shutting down, force-pushing
/// main). Matching is on command position, so `git commit -m "rm -rf /"`
/// is fine.
String? floorReason(String command) {
  final squeezed = command.replaceAll(RegExp(r'\s+'), '');
  if (_forkBomb.hasMatch(squeezed)) return 'a fork bomb';
  if (_toRootShell.hasMatch(command)) return 'pipes a download into a root shell';
  for (final part in _parts(command, 0)) {
    final words = _words(part.text);
    // `echo ~ | xargs rm -rf` deletes what was piped in.
    final piped = [
      if (part.viaXargs && part.input != null)
        for (final a in _words(part.input!).skip(1))
          if (!a.startsWith('-')) a,
    ];
    // A part whose program can't be told reads as every command it might be.
    final starts = _unparsed(words.first)
        ? [
            for (var i = 1; i < words.length; i++)
              if (!_unparsed(words[i])) i,
          ]
        : [0];
    for (final i in starts) {
      final w = words.sublist(i);
      if (_floorOf(w, [...w.skip(1), ...piped], w.join(' ')) case final why?) return why;
    }
  }
  return null;
}

/// The floor for one command: its words [w], arguments [args] (piped
/// ones included) and text [part].
String? _floorOf(List<String> w, List<String> args, String part) {
  final targets = args.where((a) => !a.startsWith('-'));
  switch (w.first) {
    case 'rm' when args.contains('--no-preserve-root'):
      return 'deletes the whole file system';
    case 'rm' when _recursive(args) && targets.any(_isRootTarget):
      return 'deletes the file system, a home folder or a system folder';
    case 'chmod' || 'chown' || 'chgrp' when _recursive(args, lowerR: false) && targets.any(_isRootTarget):
      return 'changes ownership or permissions of a system or home folder';
    case 'find'
        when args.isNotEmpty &&
            _isRootTarget(args.firstWhere((a) => !a.startsWith('-'), orElse: () => '')) &&
            (args.contains('-delete') || RegExp(r'-exec(dir)? (\S*/)?rm ').hasMatch(part)):
      return 'deletes files across a system or home folder';
    case 'dd' when args.any((a) => a.startsWith('of=/dev/')):
      return 'writes raw data to a device';
    case 'diskutil'
        when args.isNotEmpty &&
            const {
              'eraseDisk', 'eraseVolume', 'partitionDisk', 'zeroDisk', 'randomDisk', 'secureErase', 'reformat', //
              'splitPartition', 'mergePartitions', 'deleteVolume',
            }.contains(args.first):
      return 'erases or repartitions a disk';
    case 'shutdown' || 'reboot' || 'halt' || 'poweroff':
      return 'shuts down or restarts the computer';
    case 'init' when args.length == 1 && (args.first == '0' || args.first == '6'):
      return 'shuts down or restarts the computer';
    case 'systemctl' || 'launchctl'
        when args.any((a) => const {'poweroff', 'reboot', 'halt', 'kexec', 'userspace'}.contains(a)):
      return 'shuts down or restarts the computer';
    case 'kill' when args.length >= 2 && args.skip(1).contains('-1'):
      return 'kills every process you own';
    case 'pkill' || 'killall' when _userApp.hasMatch(targets.join(' ')):
      return 'quits one of your own apps (a browser, Finder, a terminal or chat app); stop only processes you '
          'started, by the PID you saved';
  }
  if (RegExp(r'^(mkfs(\.\w+)?|newfs(_\w+)?|wipefs|fdisk|sfdisk|gdisk|cfdisk|parted)$').hasMatch(w.first)) {
    return 'formats or repartitions a disk';
  }
  if (RegExp(r'>\s*' + _diskDevice.pattern).hasMatch(part)) return 'writes raw data to a disk device';
  final push = _push(w);
  if (push != null && push.main && (push.force || push.delete)) {
    return 'force-pushes or deletes main/master on the remote';
  }
  return null;
}

/// Apps the user works in: an agent quitting them (a browser it wanted for
/// screenshots, say) closes the user's own windows and tabs.
final _userApp = RegExp(
  r'google chrome|\bchrome\b|chromium|safari|firefox|\barc\b|brave|microsoft edge|\bedge\b|\bfinder\b|\bdock\b|'
  r'terminal|iterm|warp|slack|discord|\bmail\b|messages|zoom|\bnotes\b|everyai|visual studio code|\bcode\b|'
  r'cursor|xcode|windowserver|loginwindow|systemuiserver',
  caseSensitive: false,
);

final _pipeToShell = RegExp(
  r'\b(curl|wget|fetch)\b[^|;&]*\|\s*(\S*/)?(ba|z|da|k|fi)?sh\b|'
  r'(ba|z)?sh\s+<\(\s*(curl|wget)|'
  r'''-c\s+["']?\$\(\s*(curl|wget)''',
);
final _sql = RegExp(r'\b(drop\s+(table|database|schema)|truncate\s+table)\b', caseSensitive: false);
final _homeSecrets = RegExp(
  r'>>?\s*(~|\$HOME|\$\{HOME\})/\.(ssh|zshrc|zshenv|zprofile|bashrc|bash_profile|profile|gitconfig|aws|kube|netrc|'
  r'gnupg|config/gh)',
);

/// Why [command] needs the user's eyes even when rules or the mode would
/// run it, or null. Full auto skips this check (the floor still holds).
String? dangerReason(String command) {
  if (floorReason(command) case final why?) return why;
  if (RegExp(r'(^|[\s;&|(`])(sudo|doas)\s').hasMatch(command)) return 'runs as administrator';
  if (_pipeToShell.hasMatch(command)) return 'runs a script downloaded from the internet';
  if (_sql.hasMatch(command)) return 'drops database tables';
  if (_homeSecrets.hasMatch(command)) return 'writes to a sensitive file in your home folder';
  if (RegExp(r'\bxargs\b[^|;&]*\brm\b').hasMatch(command)) return 'deletes files';
  for (final part in commandParts(command)) {
    final w = _words(part);
    final args = w.sublist(1);
    final why = switch (w.first) {
      'rm' when _recursive(args) => 'deletes files recursively',
      'chmod' || 'chown' || 'chgrp' when _recursive(args, lowerR: false) => 'changes permissions recursively',
      'chmod' when args.any((a) => RegExp(r'^0?777$').hasMatch(a)) => 'makes files writable by everyone',
      'eval' => 'runs a computed command',
      'dd' || 'shred' || 'truncate' => 'overwrites data',
      'kill' when args.any((a) => const {'-9', '-KILL', '-SIGKILL', '-s'}.contains(a)) => 'force-kills processes',
      'pkill' || 'killall' => 'kills processes by name',
      'find' when args.contains('-delete') || RegExp(r'-exec(dir)? (\S*/)?rm ').hasMatch(part) =>
        'deletes the files it finds',
      'rsync' when args.any((a) => a.startsWith('--delete')) => 'deletes files at the destination',
      'crontab' when args.contains('-r') => 'removes scheduled jobs',
      'launchctl' when args.any((a) => const {'unload', 'remove', 'bootout', 'disable'}.contains(a)) =>
        'changes system services',
      'defaults' when args.contains('delete') => 'deletes system preferences',
      'security' when args.any((a) => a.startsWith('delete-')) => 'deletes keychain items',
      'docker' when args.any((a) => a == 'prune') || (args.length >= 2 && args[0] == 'volume' && args[1] == 'rm') =>
        'deletes Docker data',
      'npm' ||
      'pnpm' ||
      'yarn' ||
      'cargo' ||
      'twine' when args.any((a) => a == 'publish' || a == 'upload') => 'publishes a package',
      'dart' || 'flutter' when args.length >= 2 && args[0] == 'pub' && args[1] == 'publish' => 'publishes a package',
      'gem' when args.isNotEmpty && args.first == 'push' => 'publishes a package',
      'docker' when args.isNotEmpty && args.first == 'push' => 'publishes an image',
      'gh' when _gh(args) => 'changes GitHub (merges, releases, deletes or posts)',
      _ => null,
    };
    if (why != null) return why;
    if (_gitDanger(w) case final why?) return why;
  }
  return null;
}

bool _gh(List<String> args) {
  if (args.length < 2) return false;
  return switch (args[0]) {
    'repo' => const {'delete', 'archive', 'rename', 'edit'}.contains(args[1]),
    'pr' => const {'merge', 'close'}.contains(args[1]),
    'release' => const {'create', 'delete', 'upload'}.contains(args[1]),
    'issue' => const {'create', 'comment', 'edit'}.contains(args[1]),
    'secret' || 'variable' => const {'set', 'delete', 'remove'}.contains(args[1]),
    _ => false,
  };
}

String? _gitDanger(List<String> w) {
  if (_push(w) case final p? when p.force || p.delete || p.mirror) return 'rewrites or deletes remote history';
  final git = _git(w);
  if (git == null) return null;
  final (sub, args) = git;
  final positionals = args.where((a) => !a.startsWith('-')).toList();
  return switch (sub) {
    'reset' when args.contains('--hard') || args.contains('--merge') || args.contains('--keep') =>
      'discards uncommitted changes',
    'clean' when _shortFlag(args, 'f') || args.contains('--force') => 'deletes untracked files',
    'checkout' when args.contains('--') || positionals.contains('.') || _shortFlag(args, 'f') =>
      'discards uncommitted changes',
    'restore' when !args.contains('--staged') || args.contains('--worktree') => 'discards uncommitted changes',
    'switch' when args.contains('--discard-changes') || _shortFlag(args, 'f') => 'discards uncommitted changes',
    'branch' when _shortFlag(args, 'D') || (args.contains('--delete') && args.contains('--force')) =>
      'deletes a branch that may not be merged',
    'stash' when positionals.isNotEmpty && (positionals.first == 'drop' || positionals.first == 'clear') =>
      'deletes stashed changes',
    'filter-branch' || 'filter-repo' => 'rewrites history',
    'update-ref' when _shortFlag(args, 'd') => 'deletes a ref',
    'reflog' when positionals.isNotEmpty && (positionals.first == 'expire' || positionals.first == 'delete') =>
      'deletes the reflog that undo relies on',
    'gc' when args.any((a) => a.startsWith('--prune')) => 'deletes unreachable commits',
    _ => null,
  };
}

/// Why writing [path] needs the user's eyes, or null.
/// Why an edit outside the session's folder asks first, in every mode.
const outsideProject = 'edits a file outside the project';

/// Whether writing [path] stays in scratch space: under the project's
/// `.everyai/scratch/` or one of [tempDirs], with no `..` and nothing that
/// [editDangerReason] would flag inside that folder (`.git`, `.env`, keys).
/// A relative [path] is taken from [workingDir]. Inside a project that lives
/// in a temp folder only its own scratch folder counts, so its edits still
/// ask. [isLink] (when given) refuses a path with a symlink between the
/// project (or the temp folder) and the file: a cloned repo's
/// `.everyai/scratch` could point anywhere.
bool isScratchWrite(
  String path, {
  String? workingDir,
  List<String> tempDirs = const [],
  bool Function(String path)? isLink,
}) {
  if (path.isEmpty || path.split('/').contains('..')) return false;
  final dir = workingDir == null || workingDir.isEmpty ? null : workingDir.replaceAll(RegExp(r'/+$'), '');
  final abs = path.startsWith('/') ? path : (dir == null ? null : '$dir/$path');
  if (abs == null) return false;
  final inProject = dir != null && _privateAliases(dir).any((d) => abs == d || abs.startsWith('$d/'));
  final roots = [
    if (dir != null) (from: '$dir/', root: '$dir/.everyai/scratch/'),
    if (!inProject)
      for (final t in tempDirs) (from: t.endsWith('/') ? t : '$t/', root: t.endsWith('/') ? t : '$t/'),
  ];
  for (final (:from, :root) in roots) {
    if (!abs.startsWith(root) || abs.length <= root.length) continue;
    if (editDangerReason(abs, workingDir: root.substring(0, root.length - 1)) != null) return false;
    if (isLink == null) return true;
    // Every folder below [from] down to the file itself (the temp root may be a link: /tmp on macOS).
    var at = from.substring(0, from.length - 1);
    for (final part in abs.substring(from.length).split('/')) {
      if (part.isEmpty) continue;
      at = '$at/$part';
      if (isLink(at)) return false;
    }
    return true;
  }
  return false;
}

/// [dir] and its macOS `/private` twin (`/tmp`, `/var` are links into it).
List<String> _privateAliases(String dir) => [
  dir,
  if (dir.startsWith('/private/')) dir.substring('/private'.length),
  if (dir.startsWith('/tmp/') || dir.startsWith('/var/')) '/private$dir',
];

/// Whether [command] only makes folders (`mkdir`, `mkdir -p`) and every
/// folder passes [scratch]. Words with expansions or globs don't count.
bool _mkdirsOnly(String command, bool Function(String) scratch) {
  final segments = shellSegments(command);
  if (segments == null || segments.isEmpty) return false;
  for (final w in segments) {
    if (w.first != 'mkdir') return false;
    final paths = [
      for (final a in w.skip(1))
        if (!a.startsWith('-')) a,
    ];
    if (w.skip(1).any((a) => a.startsWith('-') && a != '-p' && a != '--parents')) return false;
    if (paths.isEmpty || paths.any((a) => a.contains(RegExp(r'[$`*?~\\]')) || !scratch(a))) return false;
  }
  return true;
}

String? editDangerReason(String path, {String? workingDir}) {
  final dir = workingDir;
  if (dir != null && dir.isNotEmpty && path.startsWith('/')) {
    final base = dir.endsWith('/') ? dir : '$dir/';
    if (!path.startsWith(base) && path != dir) return outsideProject;
  }
  final rel = relativeTo(path, dir);
  final parts = rel.split('/');
  if (parts.contains('..')) return outsideProject;
  if (parts.contains('.git')) return "edits git's internal files";
  if (rel.startsWith('.everyai/settings') || rel.contains('/.everyai/settings')) {
    return "edits the agent's own settings and permissions";
  }
  final name = parts.last;
  if (RegExp(r'^\.env(\..+)?$').hasMatch(name) && !RegExp(r'\.(example|sample|template|dist)$').hasMatch(name)) {
    return 'edits an environment file, which may hold secrets';
  }
  if (const {'id_rsa', 'id_ed25519', '.netrc', '.npmrc', '.pypirc'}.contains(name)) {
    return 'edits a file that may hold credentials';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Remembered approvals.

/// Commands where any argument changes what runs, so only the exact
/// command is remembered.
const _exactOnly = {
  'python', 'python3', 'node', 'bash', 'sh', 'zsh', 'fish', 'ruby', 'perl', 'php', 'deno', 'bun', 'npx', 'pnpx', //
  'bunx', 'uvx', 'xargs', 'env', 'sudo', 'doas', 'eval', 'exec', 'timeout', 'nohup', 'ssh', 'scp', 'osascript',
  'rm', 'mv', 'cp', 'ln', 'rmdir', 'unlink', 'chmod', 'chown', 'kill', 'curl', 'wget', 'open', 'source', '.',
};

/// Programs whose first argument picks the action (`git commit`, `npm test`).
const _twoWord = {
  'git', 'npm', 'pnpm', 'yarn', 'cargo', 'go', 'dart', 'flutter', 'docker', 'kubectl', 'gh', 'uv', 'pip', 'pip3', //
  'brew', 'swift', 'zig', 'make', 'mvn', 'gradle', './gradlew', 'poetry', 'mix', 'dotnet', 'rails', 'pod',
  'xcodebuild', 'cmake', 'just', 'task', 'composer', 'bundle', 'rake', 'melos', 'nx', 'turbo',
};

/// Two-word commands whose next word picks the action (`npm run build`).
const _threeWord = {
  'npm run',
  'pnpm run',
  'yarn run',
  'docker compose',
  'dart pub',
  'flutter pub',
  'gh pr',
  'gh issue',
};

/// The rule that "allow for this session" or "always allow" would store
/// for [call], or null when it can't be remembered: compound or unparsed
/// commands, dangerous actions, edits outside the project. Commands keep
/// their program and subcommand (`npm run build` gives `npm run build *`);
/// edits keep the file (`Edit(lib/main.dart)`); MCP tools keep the tool
/// (`Mcp(browser_take_screenshot)`).
String? rememberPattern(ActionCall call, {String? workingDir}) {
  final all = rememberPatterns(call, workingDir: workingDir);
  return all == null || all.length != 1 ? null : all.single;
}

/// The rules "allow similar for this session" stores for [call]: one per simple command of a chain
/// (`cd app && npm test` gives `cd *` and `npm test *`), else as [rememberPattern]. Null when any part can't be
/// remembered (dangerous, unparsed, `$(…)`).
List<String>? rememberPatterns(ActionCall call, {String? workingDir}) {
  if (_command(call) case final command?) {
    // A risky command is remembered word for word.
    if (dangerReason(command) != null) return ['Exact(${_collapse(command)})'];
    final segments = shellSegments(command);
    if (segments == null || segments.isEmpty) return null;
    final out = <String>[];
    for (final w in segments) {
      final p = _segmentPattern(w);
      if (p == null) return null;
      if (!out.contains(p)) out.add(p);
    }
    return out;
  }
  final single = _singlePattern(call, workingDir: workingDir);
  return single == null ? null : [single];
}

/// "Allow all similar for this session": the whole kind of [call]. Any command (`*`: the floor and risky commands
/// still ask, and so does anything the parser can't vouch for), any edit in the project (`Edit(**)`: edits outside it
/// still ask), any MCP tool (`Mcp(*)`). Null for anything else.
String? broadPattern(ActionCall call) {
  if (_command(call) != null) return '*';
  if (_editPath(call) != null || _editPaths(call).isNotEmpty) return 'Edit(**)';
  if (isMcpTool(call)) return 'Mcp(*)';
  return null;
}

/// What a broad pattern covers, for the button ("all commands").
String broadLabel(String pattern) => switch (pattern) {
  '*' => 'all commands',
  'Edit(**)' => 'all edits in the project',
  'Mcp(*)' => 'all MCP tools',
  _ => pattern,
};

String? _segmentPattern(List<String> w) {
  if (w.isEmpty || RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(w.first)) return null;
  // An exact rule must read back as the same words.
  bool plain(String x) => x.isNotEmpty && !x.contains('*') && !x.contains('?') && !x.contains(' ');
  String? exact() => w.every(plain) ? w.join(' ') : null;
  if (_exactOnly.contains(w.first)) return exact();
  final arity = w.length >= 2 && _threeWord.contains('${w[0]} ${w[1]}')
      ? 3
      : _twoWord.contains(w.first)
      ? 2
      : 1;
  final prefix = w.take(arity).toList();
  if (prefix.skip(1).any((x) => x.startsWith('-'))) return exact();
  if (!prefix.every(plain)) return null;
  return '${prefix.join(' ')} *';
}

String? _singlePattern(ActionCall call, {String? workingDir}) {
  if (_editPath(call) case final path?) {
    if (path.isEmpty) return null;
    final danger = editDangerReason(path, workingDir: workingDir);
    // Outside the project: the file's folder, by its absolute path (it covers everything in it).
    if (danger == outsideProject) {
      if (!path.startsWith('/') || path.split('/').contains('..') || path.contains(RegExp(r'[*?\[)]'))) return null;
      final cut = path.lastIndexOf('/');
      return cut <= 0 ? null : 'Edit(${path.substring(0, cut)})';
    }
    final rel = relativeTo(path, workingDir);
    if (rel.startsWith('/') && workingDir != null && workingDir.isNotEmpty) return null;
    if (rel.contains('*') || rel.contains('?') || rel.contains(')')) return null;
    // A risky file (.env, .git, the agent's settings) is remembered alone; other edits cover the file.
    return 'Edit($rel)';
  }
  if (_ownTool(call) && call.toolName.isNotEmpty && !call.toolName.contains(RegExp(r'[*?)]'))) {
    return 'Tool(${call.toolName})';
  }
  if (isMcpTool(call) && call.toolName.isNotEmpty) {
    if (call.toolName.contains('*') || call.toolName.contains('?') || call.toolName.contains(')')) return null;
    return 'Mcp(${call.toolName})';
  }
  return null;
}

/// How long an approval lasts.
enum ApprovalScope {
  /// This action only.
  once,

  /// Until the app quits.
  session,

  /// Until the app quits, the whole kind of action (every command, every edit in the project, every MCP tool; see
  /// [broadPattern]). The floor and risky actions still ask.
  sessionAll,

  /// Stored in the project's permissions.
  always,
}

// ---------------------------------------------------------------------------
// What the agent reads when an action doesn't run.

/// Why an action the agent asked for did not run.
enum DenialKind {
  /// The user said no.
  denied,

  /// Nobody answered in time.
  timedOut,

  /// The user stopped the turn while the action waited.
  cancelled,
}

const _stopClause =
    'Do not retry it, do not rephrase it, and do not reach the same outcome another way '
    '(a different command, tool or file).';

/// The tool result the agent reads for [kind]. The text is fixed so the
/// agent always gets the same unambiguous signal; why the app asked
/// ([asked], see approval_reason.dart) comes next, then the user's [reason]
/// word for word.
String denialMessage(DenialKind kind, {String? reason, String? asked}) {
  final said = reason?.trim() ?? '';
  final why = asked?.trim() ?? '';
  final because = why.isEmpty ? '' : "\n\nIt needed the user's OK because: $why";
  final head = switch (kind) {
    DenialKind.denied => '$deniedLead $_stopClause',
    DenialKind.timedOut =>
      '$timedOutLead Silence is not consent. $_stopClause Carry on with work that does not need it, or end your '
          'turn and say what is waiting on the user.',
    DenialKind.cancelled => '$cancelledLead $_stopClause',
  };
  if (said.isEmpty) {
    return kind == DenialKind.denied
        ? '$head If you cannot continue without it, end your turn and say what you needed and why.$because'
        : '$head$because';
  }
  return '$head$because\n\n$_reasonLead$said';
}

const _reasonLead = "The user's reason, word for word (follow it if it asks for something else):\n";

/// The words the user typed in a [denialMessage], or null when [message]
/// holds only the fixed text (or is some other refusal).
String? typedReason(String? message) {
  final at = message?.indexOf(_reasonLead) ?? -1;
  if (at < 0) return null;
  final said = message!.substring(at + _reasonLead.length).trim();
  return said.isEmpty ? null : said;
}

const deniedLead = 'The user did NOT consent to this action, and it was not run.';
const timedOutLead = 'The approval request timed out with no answer, so this action was not run.';
const cancelledLead = 'The user cancelled this action before it ran.';
const _blockedLead = 'Blocked, not run:';

/// What the agent reads when the policy blocks [blocked] (each with its
/// decision) out of a [batch] of pending actions.
String policyDenial(List<(ActionCall, Decision)> blocked, {int batch = 1}) {
  final b = StringBuffer();
  for (final (call, d) in blocked) {
    final edits = _editPaths(call);
    final what = _command(call) ?? (edits.isEmpty ? null : edits.join(', ')) ?? _readPath(call) ?? call.toolName;
    b.write('$_blockedLead `${_short(what)}` ');
    if (d.source == DecisionSource.floor) {
      b.writeln('${d.why}. This is on the safety floor and never runs, in any mode.');
    } else {
      b.writeln('the user\'s permission rule `${d.rule}` forbids it.');
    }
  }
  b.write('The user did NOT consent to this action. $_stopClause');
  if (batch > blocked.length) {
    b.write(' Nothing else in this batch ran either; re-issue the other actions on their own if you still need them.');
  }
  b.write(' If you cannot finish without it, end your turn and explain what you needed.');
  return b.toString();
}

String _short(String s) {
  final line = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  return line.length <= 120 ? line : '${line.substring(0, 117)}…';
}

/// A short, user-facing version of a denial the agent was sent, for the
/// transcript ("Denied: use yarn"), or [text] itself when it isn't one.
String denialSummary(String text) {
  String withReason(String label) {
    final i = text.indexOf('word for word');
    if (i < 0) return label;
    final nl = text.indexOf('\n', i);
    return nl < 0 ? label : '$label: ${text.substring(nl + 1).trim()}';
  }

  if (text.startsWith(deniedLead)) return withReason('Denied');
  if (text.startsWith(timedOutLead)) return withReason('No answer in time');
  if (text.startsWith(cancelledLead)) return withReason('Cancelled');
  if (text.startsWith(_blockedLead)) {
    final line = text.split('\n').first.substring(_blockedLead.length).trim();
    final reason = line.contains('` ') ? line.substring(line.indexOf('` ') + 2) : line;
    return 'Blocked: ${reason.split('. This is').first.replaceAll(RegExp(r'\.$'), '')}';
  }
  return text;
}
