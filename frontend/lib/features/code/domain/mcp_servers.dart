import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'mcp_tool_check.dart';
import 'permissions.dart' show dangerReason, floorReason;

export 'mcp_tool_check.dart' show McpToolReview, McpToolsReport;

/// How the harness reaches an MCP server.
enum McpTransport {
  /// A local program the harness starts and talks to over stdin/stdout.
  stdio('Local command'),

  /// Streamable HTTP.
  http('Remote (HTTP)'),

  /// The legacy HTTP + SSE transport.
  sse('Remote (SSE)');

  const McpTransport(this.label);
  final String label;

  bool get remote => this != stdio;

  static McpTransport parse(Object? v) => values.where((t) => t.name == v).firstOrNull ?? stdio;
}

/// One MCP server the user configured for Code sessions. Sessions get it
/// through `SessionSpec.mcpConfig` (`{command, args, env}` or `{url,
/// transport, headers}`, the shape OpenHands' agent-server used), and the
/// harness's MCP client owns the protocol.
///
/// A local command runs on this machine as the user (the app is not
/// sandboxed), so it is only passed on after the user approved exactly
/// this command, arguments and environment ([approved] == [consentKey]).
@immutable
final class McpServer {
  const McpServer({
    required this.name,
    this.transport = McpTransport.stdio,
    this.command = '',
    this.args = const [],
    this.env = const {},
    this.url = '',
    this.headers = const {},
    this.enabled = true,
    this.approved,
    this.description = '',
    this.preset,
    this.pinned,
    this.pending = const [],
  });

  /// The key in `mcp_config`; letters, digits, `_` and `-`.
  final String name;
  final McpTransport transport;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final String url;
  final Map<String, String> headers;
  final bool enabled;

  /// The [consentKey] the user approved, for local commands.
  final String? approved;
  final String description;

  /// The [McpPreset.id] this entry came from.
  final String? preset;

  /// The tools sessions may show the model: the server's own tool name to
  /// its `mcpToolDigest`. Null until a session first connected (then the
  /// clean tools are pinned). Kept when the entry is edited, so a new
  /// version of the server shows up as changes instead of being trusted.
  final Map<String, String>? pinned;

  /// Tools left out of sessions until the user allows them in Settings:
  /// changed since they were pinned, new, or flagged by `scanMcpTool`.
  final List<McpToolReview> pending;

  static final namePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$');

  /// What the user approves: the command, its arguments and its environment.
  /// Any change to them needs a new approval.
  String get consentKey => jsonEncode({
    'command': command,
    'args': args,
    'env': {for (final k in env.keys.toList()..sort()) k: env[k]},
  });

  /// A local command that hasn't been approved as it stands.
  bool get needsConsent => transport == McpTransport.stdio && approved != consentKey;

  /// Whether sessions get this server: enabled, valid, approved, and not on
  /// the safety floor.
  bool get active => enabled && problem == null && !needsConsent && !blocked;

  /// The command hits the safety floor ([floorReason]): it is never run.
  bool get blocked =>
      transport == McpTransport.stdio && reviewMcpServer(this).any((f) => f.level == McpFlagLevel.blocked);

  /// What is wrong with the entry, or null.
  String? get problem {
    if (!namePattern.hasMatch(name)) return 'The name may use letters, digits, _ and - (up to 40).';
    if (transport == McpTransport.stdio) {
      if (command.trim().isEmpty) return 'A local server needs a command.';
      return null;
    }
    final u = Uri.tryParse(url.trim());
    if (u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty) {
      return 'A remote server needs an http(s) URL.';
    }
    return null;
  }

  /// The command as one shell line, quoted where needed (for display and
  /// for the dangerous-pattern checks; the server is started without a shell).
  String get commandLine => shellJoin([command, ...args]);

  /// This server's entry in the session's `mcp_config`.
  Map<String, Object?> toAgentConfig() => transport == McpTransport.stdio
      ? {
          'command': command,
          if (args.isNotEmpty) 'args': args,
          if (env.isNotEmpty) 'env': env,
          if (description.isNotEmpty) 'description': description,
          'pinned': ?pinned,
        }
      : {
          'url': url.trim(),
          'transport': transport.name,
          if (headers.isNotEmpty) 'headers': headers,
          if (description.isNotEmpty) 'description': description,
          'pinned': ?pinned,
        };

  McpServer copyWith({
    String? name,
    McpTransport? transport,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
    String? Function()? approved,
    String? description,
    Map<String, String>? Function()? pinned,
    List<McpToolReview>? pending,
  }) => McpServer(
    name: name ?? this.name,
    transport: transport ?? this.transport,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    enabled: enabled ?? this.enabled,
    approved: approved == null ? this.approved : approved(),
    description: description ?? this.description,
    preset: preset,
    pinned: pinned == null ? this.pinned : pinned(),
    pending: pending ?? this.pending,
  );

  /// This entry approved as it stands.
  McpServer approve() => copyWith(approved: () => consentKey);

  /// This entry with every [pending] tool allowed as it was seen.
  McpServer allowPending() =>
      copyWith(pinned: () => {...?pinned, for (final p in pending) p.name: p.digest}, pending: const []);

  static Map<String, String> _strings(Object? v) => {
    if (v is Map<String, Object?>)
      for (final e in v.entries)
        if (e.value is String) e.key: e.value! as String,
  };

  static McpServer? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    final args = json['args'];
    final pinned = json['pinned'];
    final pending = json['pending'];
    return McpServer(
      name: name,
      transport: McpTransport.parse(json['transport']),
      command: json['command'] as String? ?? '',
      args: [
        if (args is List<Object?>)
          for (final a in args)
            if (a is String) a,
      ],
      env: _strings(json['env']),
      url: json['url'] as String? ?? '',
      headers: _strings(json['headers']),
      enabled: json['enabled'] != false,
      approved: json['approved'] as String?,
      description: json['description'] as String? ?? '',
      preset: json['preset'] as String?,
      pinned: pinned is Map<String, Object?> ? _strings(pinned) : null,
      pending: [
        if (pending is List<Object?>)
          for (final p in pending) ?McpToolReview.fromJson(p),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'transport': transport.name,
    if (command.isNotEmpty) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (env.isNotEmpty) 'env': env,
    if (url.isNotEmpty) 'url': url,
    if (headers.isNotEmpty) 'headers': headers,
    'enabled': enabled,
    'approved': ?approved,
    if (description.isNotEmpty) 'description': description,
    'preset': ?preset,
    'pinned': ?pinned,
    if (pending.isNotEmpty) 'pending': [for (final p in pending) p.toJson()],
  };
}

/// The MCP servers kept in the app (Preferences `code.mcp_servers`): one
/// global list and one per project, by project id. A project entry with the
/// same name as a global one replaces it in that project's sessions.
///
/// Servers come only from here, never from a repository's files: a cloned
/// repo can't make the app run a command.
@immutable
final class StoredMcpServers {
  const StoredMcpServers({this.global = const [], this.projects = const {}});

  final List<McpServer> global;
  final Map<String, List<McpServer>> projects;

  List<McpServer> listFor(String? projectId) => projectId == null ? global : projects[projectId] ?? const [];

  /// The servers a session in [projectId] sees: global ones, then the
  /// project's, which win on a name clash.
  List<McpServer> serversFor(String? projectId) {
    final byName = {for (final s in global) s.name: s};
    for (final s in projects[projectId] ?? const <McpServer>[]) {
      byName[s.name] = s;
    }
    return byName.values.toList();
  }

  /// The `mcp_config` for a session in [projectId]: active servers only,
  /// sorted by name so the agent's tool list stays the same between sessions
  /// (and the model's prompt cache holds). The map is flat, `{name: server}`.
  ///
  /// For an [outside] agent (ACP, which connects to whole servers itself and
  /// can't be given some of a server's tools), a server with tools waiting
  /// for the user's review is left out entirely, all its tools with it.
  /// Known gap: only EveryAI sessions see a server's tools, so a server never
  /// used in one has no pins or reviews and goes to ACP agents unchecked, and
  /// a change shows only after an EveryAI session connects to it again.
  Map<String, Object?> mcpConfigFor(String? projectId, {bool outside = false}) {
    final active = serversFor(projectId).where((s) => s.active && !(outside && s.pending.isNotEmpty)).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return {for (final s in active) s.name: s.toAgentConfig()};
  }

  /// [reports] from a session in [projectId] recorded: each server's new
  /// pins added, its pending list replaced (so every session reporting the
  /// same thing changes nothing). The entry is the one the session used: the
  /// project's, else the global one.
  ///
  /// A pin already stored wins over a first-use one (two sessions that both
  /// started before either reported): a tool that changed between them is
  /// then held as changed at the next session, never re-pinned unseen. A
  /// server that offered no tools yet (a missing token, toolsets off) stays
  /// unpinned, so its tools are still trusted on first use once it has some.
  StoredMcpServers withReports(String? projectId, Map<String, McpToolsReport> reports) {
    var next = this;
    for (final MapEntry(key: name, value: r) in reports.entries) {
      final scope = projectId != null && (projects[projectId]?.any((s) => s.name == name) ?? false) ? projectId : null;
      next = next.withList(scope, [
        for (final s in next.listFor(scope))
          s.name != name
              ? s
              : s.pinned == null && r.pin.isEmpty && r.pending.isEmpty
              ? s.copyWith(pending: const [])
              : s.copyWith(pinned: () => {...r.pin, ...?s.pinned}, pending: r.pending),
      ]);
    }
    return next;
  }

  StoredMcpServers withList(String? projectId, List<McpServer> list) => projectId == null
      ? StoredMcpServers(global: list, projects: projects)
      : StoredMcpServers(global: global, projects: {...projects, projectId: list});

  factory StoredMcpServers.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const StoredMcpServers();
    List<McpServer> list(Object? v) => [
      if (v is List<Object?>)
        for (final s in v) ?McpServer.fromJson(s),
    ];
    final projects = json['projects'];
    return StoredMcpServers(
      global: list(json['global']),
      projects: {
        if (projects is Map<String, Object?>)
          for (final e in projects.entries) e.key: list(e.value),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'global': [for (final s in global) s.toJson()],
    'projects': {
      for (final e in projects.entries)
        if (e.value.isNotEmpty) e.key: [for (final s in e.value) s.toJson()],
    },
  };
}

/// How much a finding in the consent dialog matters.
enum McpFlagLevel {
  /// The safety floor: the server can't be approved.
  blocked,
  danger,
  warning,
  info,
}

@immutable
final class McpFlag {
  const McpFlag(this.level, this.text);
  final McpFlagLevel level;
  final String text;

  @override
  bool operator ==(Object other) => other is McpFlag && other.level == level && other.text == text;

  @override
  int get hashCode => Object.hash(level, text);

  @override
  String toString() => '${level.name}: $text';
}

const _loaderEnv = {
  'LD_PRELOAD',
  'LD_LIBRARY_PATH',
  'NODE_OPTIONS',
  'NODE_PATH',
  'PYTHONSTARTUP',
  'PYTHONPATH',
  'PATH',
  'BASH_ENV',
  'ENV',
  'ZDOTDIR',
  'PERL5OPT',
  'PERL5LIB',
  'RUBYOPT',
  'RUBYLIB',
  'GIT_SSH_COMMAND',
};
final _secretKey = RegExp(r'(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH)', caseSensitive: false);
final _sensitivePath = RegExp(
  r'(^|[\s=/~])(\.ssh|\.aws|\.gnupg|\.kube|\.netrc|\.config/gh|\.docker/config\.json|Keychains|id_(rsa|ed25519|ecdsa))'
  r'|^/(etc|private/etc|System|Library)(/|$)|^(~|\$HOME|/Users/[^/]+|/home/[^/]+)/?$|^/$',
);
const _shells = {'sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'csh', 'tcsh'};
const _interpreters = {'python', 'python3', 'node', 'deno', 'bun', 'ruby', 'perl', 'osascript'};

/// What the consent dialog points out about a local server [s], most
/// serious first. It reuses the Code permission checks ([floorReason],
/// [dangerReason]) on the command line and adds MCP-specific ones: inline
/// scripts, packages fetched at start-up and whether they are pinned,
/// environment variables that change how programs load, sensitive paths.
List<McpFlag> reviewMcpServer(McpServer s) {
  final flags = <McpFlag>[];
  void add(McpFlagLevel level, String text) {
    final f = McpFlag(level, text);
    if (!flags.contains(f)) flags.add(f);
  }

  if (s.transport.remote) {
    final u = Uri.tryParse(s.url.trim());
    if (u != null && u.isScheme('http') && !_loopback(u.host)) {
      add(McpFlagLevel.warning, 'Unencrypted connection (http) to ${u.host}.');
    }
    for (final k in s.headers.keys) {
      if (_secretKey.hasMatch(k)) add(McpFlagLevel.info, 'Sends the $k header to ${u?.host ?? 'the server'}.');
    }
    flags.sort((a, b) => a.level.index.compareTo(b.level.index));
    return flags;
  }

  final line = s.commandLine;
  if (floorReason(line) case final why?) add(McpFlagLevel.blocked, _sentence(why));
  if (dangerReason(line) case final why?) add(McpFlagLevel.danger, _sentence(why));

  final program = _basename(s.command);
  final args = s.args;
  if (const {'sudo', 'doas', 'su', 'pkexec'}.contains(program)) {
    add(McpFlagLevel.danger, 'Runs as administrator.');
  }
  if (_shells.contains(program) && args.any((a) => RegExp(r'^-\w*c').hasMatch(a))) {
    add(McpFlagLevel.danger, 'Runs an inline shell script.');
  } else if (_interpreters.contains(program) && args.any((a) => const {'-c', '-e', '--eval', '-p'}.contains(a))) {
    add(McpFlagLevel.danger, 'Runs inline code.');
  }
  if (program == 'eval') add(McpFlagLevel.danger, 'Runs a computed command.');

  if (_package(program, args) case (final source, final spec, final pinned)?) {
    add(McpFlagLevel.info, 'Downloads $spec from $source and runs it.');
    if (!pinned) {
      add(McpFlagLevel.warning, '$spec is not pinned to a version: a new release runs without asking again.');
    }
  }
  if (program == 'docker' || program == 'podman') {
    if (args.contains('--privileged')) add(McpFlagLevel.danger, 'Runs a privileged container.');
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      final mount = (a == '-v' || a == '--volume') && i + 1 < args.length
          ? args[i + 1]
          : a.startsWith('--volume=')
          ? a.substring(9)
          : a.startsWith('-v') && a.length > 2
          ? a.substring(2)
          : null;
      if (mount != null &&
          (mount.startsWith('/:') || mount.contains('docker.sock') || _sensitivePath.hasMatch(mount))) {
        add(McpFlagLevel.danger, 'Gives the container $mount.');
      }
    }
    if (args.any((a) => a == '--network=host' || a == '--net=host' || a == '--pid=host')) {
      add(McpFlagLevel.warning, "Shares this machine's network or processes with the container.");
    }
  }
  for (final a in args) {
    if (_sensitivePath.hasMatch(a)) add(McpFlagLevel.danger, 'Can reach a sensitive location: $a');
  }
  for (final k in s.env.keys) {
    if (_loaderEnv.contains(k) || k.startsWith('DYLD_')) {
      add(McpFlagLevel.danger, 'Sets $k, which changes how programs load.');
    } else if (_secretKey.hasMatch(k)) {
      add(McpFlagLevel.info, 'Passes $k to the server.');
    }
  }
  flags.sort((a, b) => a.level.index.compareTo(b.level.index));
  return flags;
}

bool _loopback(String host) => host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]';

String _basename(String path) {
  final p = path.trim();
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

String _sentence(String why) => '${why[0].toUpperCase()}${why.substring(1)}.';

/// For a package runner (`npx`, `uvx`, …): where the package comes from,
/// its spec, and whether a version is pinned.
(String, String, bool)? _package(String program, List<String> args) {
  String? firstPositional(Iterable<String> words, {Set<String> valued = const {}}) {
    final it = words.iterator;
    while (it.moveNext()) {
      final w = it.current;
      if (valued.contains(w)) {
        it.moveNext();
        continue;
      }
      if (w.startsWith('-')) continue;
      return w;
    }
    return null;
  }

  switch (program) {
    case 'npx' || 'bunx' || 'pnpx':
      final spec = firstPositional(args, valued: const {'-p', '--package', '-c', '--call'});
      return spec == null ? null : ('npm', spec, _npmPinned(spec));
    case 'pnpm' || 'yarn' || 'npm' when args.isNotEmpty && (args.first == 'dlx' || args.first == 'exec'):
      final spec = firstPositional(args.skip(1));
      return spec == null ? null : ('npm', spec, _npmPinned(spec));
    case 'uvx':
      final spec = firstPositional(args, valued: const {'--from', '--with', '--python', '-p'});
      if (spec == null) return null;
      final from = args.indexOf('--from');
      final real = from >= 0 && from + 1 < args.length ? args[from + 1] : spec;
      return ('PyPI', real, RegExp(r'(==|@)\d').hasMatch(real));
    case 'pipx' when args.isNotEmpty && args.first == 'run':
      final spec = firstPositional(args.skip(1), valued: const {'--spec'});
      return spec == null ? null : ('PyPI', spec, RegExp(r'==\d').hasMatch(spec));
    case 'docker' || 'podman' when args.isNotEmpty && args.first == 'run':
      final image = firstPositional(
        args.skip(1),
        valued: const {'-v', '--volume', '-e', '--env', '-p', '--publish', '--name', '-w', '--workdir', '--network'},
      );
      if (image == null) return null;
      final tag = image.contains('@sha256:')
          ? 'digest'
          : image.lastIndexOf(':') > image.lastIndexOf('/')
          ? image.substring(image.lastIndexOf(':') + 1)
          : 'latest';
      final pull = args.contains('--pull=always');
      return ('a container registry', image, tag != 'latest' && !pull);
  }
  return null;
}

bool _npmPinned(String spec) {
  final at = spec.lastIndexOf('@');
  if (at <= 0) return false;
  final version = spec.substring(at + 1);
  return RegExp(r'^\d').hasMatch(version);
}

/// [words] as one POSIX shell line: words with spaces or shell characters
/// are single-quoted.
String shellJoin(List<String> words) => words
    .where((w) => w.isNotEmpty)
    .map((w) => RegExp(r'''^[A-Za-z0-9_@%+=:,./~-]+$''').hasMatch(w) ? w : "'${w.replaceAll("'", r"'\''")}'")
    .join(' ');

/// Splits a line typed in the editor into arguments, honouring quotes and
/// backslashes like a shell (no expansion).
List<String> shellSplit(String line) {
  final out = <String>[];
  final cur = StringBuffer();
  var inWord = false;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < line.length) {
        cur.write(line[++i]);
      } else {
        cur.write(c);
      }
    } else if (c == "'" || c == '"') {
      quote = c;
      inWord = true;
    } else if (c == r'\' && i + 1 < line.length) {
      cur.write(line[++i]);
      inWord = true;
    } else if (c == ' ' || c == '\t' || c == '\n') {
      if (inWord) out.add(cur.toString());
      cur.clear();
      inWord = false;
    } else {
      cur.write(c);
      inWord = true;
    }
  }
  if (inWord) out.add(cur.toString());
  return out;
}

/// A ready-made server entry. Presets point at the projects' official
/// packages or endpoints; nothing is installed until a session starts the
/// server, and local ones still need the user's approval.
@immutable
final class McpPreset {
  const McpPreset({required this.id, required this.title, required this.blurb, required this.server});
  final String id;
  final String title;

  /// What it does and what to know before turning it on.
  final String blurb;
  final McpServer server;
}

const mcpPresets = [
  McpPreset(
    id: 'playwright',
    title: 'Playwright (browser and screenshots)',
    blurb:
        "Microsoft's Playwright MCP: the agent opens pages in a headless browser, clicks through them and takes "
        'screenshots to check the UI it built. Needs Node.js; downloads @playwright/mcp from npm.',
    server: McpServer(
      name: 'playwright',
      command: 'npx',
      args: ['-y', '@playwright/mcp@latest', '--headless', '--isolated'],
      description: 'Browser automation and screenshots',
      preset: 'playwright',
    ),
  ),
  McpPreset(
    id: 'penpot',
    title: 'Penpot (design files)',
    blurb:
        "Penpot's official MCP server reads and edits the design file open in Penpot. Start the Penpot MCP server "
        'and connect its plugin in Penpot first; this entry points at its local endpoint.',
    server: McpServer(
      name: 'penpot',
      transport: McpTransport.http,
      url: 'http://localhost:4401/mcp',
      description: 'Penpot design file (local MCP server and plugin)',
      preset: 'penpot',
    ),
  ),
  McpPreset(
    id: 'antv-chart',
    title: 'AntV charts',
    blurb:
        'AntV mcp-server-chart: 25+ chart tools (sankey, mind map, fishbone, …). It renders through AntV\'s hosted '
        'service by default, so chart data leaves this machine; set VIS_REQUEST_SERVER to your own renderer to '
        'keep it local. Needs Node.js.',
    server: McpServer(
      name: 'antv-chart',
      command: 'npx',
      args: ['-y', '@antv/mcp-server-chart'],
      description: 'Chart images (AntV)',
      preset: 'antv-chart',
    ),
  ),
  McpPreset(
    id: 'drawio',
    title: 'draw.io diagrams',
    blurb:
        "draw.io's hosted MCP server: the agent creates diagrams (XML or Mermaid) and gets a link that opens them "
        'in draw.io. Nothing runs on this machine; diagram content is sent to draw.io.',
    server: McpServer(
      name: 'drawio',
      transport: McpTransport.http,
      url: 'https://mcp.draw.io/mcp',
      description: 'draw.io diagrams',
      preset: 'drawio',
    ),
  ),
];

/// `KEY=value` lines (environment variables) as a map; blank lines and
/// lines without `=` are skipped.
Map<String, String> parseEnvLines(String text) => {
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty && line.indexOf('=') > 0)
      line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
};

/// `Name: value` lines (HTTP headers) as a map.
Map<String, String> parseHeaderLines(String text) => {
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty && line.indexOf(':') > 0)
      line.substring(0, line.indexOf(':')).trim(): line.substring(line.indexOf(':') + 1).trim(),
};

String envLines(Map<String, String> env) => [for (final e in env.entries) '${e.key}=${e.value}'].join('\n');

String headerLines(Map<String, String> headers) => [for (final e in headers.entries) '${e.key}: ${e.value}'].join('\n');

/// [value] with all but its last 4 characters hidden when [key] looks like a secret.
String maskSecret(String key, String value) {
  if (!_secretKey.hasMatch(key) || value.isEmpty) return value;
  return value.length <= 8 ? '••••' : '••••${value.substring(value.length - 4)}';
}

/// What the consent dialog says about local server [s], started for
/// sessions in [scope] ("every project", "MyApp"). The whole command is
/// shown, never shortened.
String mcpConsentMessage(McpServer s, {required String scope, List<McpFlag>? flags}) {
  final found = flags ?? reviewMcpServer(s);
  final b = StringBuffer()
    ..writeln(
      'Code sessions in $scope will start this program. It runs on this computer as you, with your files, '
      'network and credentials; approve it only if you trust it.',
    )
    ..writeln()
    ..writeln(s.commandLine);
  if (s.env.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Environment:');
    for (final e in s.env.entries) {
      b.writeln('${e.key}=${maskSecret(e.key, e.value)}');
    }
  }
  final serious = found.where((f) => f.level.index <= McpFlagLevel.warning.index).toList();
  final notes = found.where((f) => f.level == McpFlagLevel.info).toList();
  if (serious.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Needs a look:');
    for (final f in serious) {
      b.writeln('• ${f.text}');
    }
  }
  if (notes.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Also:');
    for (final f in notes) {
      b.writeln('• ${f.text}');
    }
  }
  b
    ..writeln()
    ..write(
      'Its tools ask before each use in Ask, Auto-edit and Plan modes, unless you allow them; Full auto runs them. '
      'The tools it offers at its first session are kept as they are; a tool that changes later, or looks like it '
      'carries hidden instructions, is left out until you review it here.',
    );
  return b.toString();
}

/// What the "Review tools" dialog says about [s]'s [McpServer.pending]
/// tools: a [message], and a [detail] with each tool's name, why it was left
/// out and what it tells the agent: its description and parameters, in
/// full, since Allow pins all of it.
({String message, String detail}) mcpToolsReviewMessage(McpServer s) {
  final b = StringBuffer();
  for (final t in s.pending) {
    if (b.isNotEmpty) b.writeln();
    b.writeln('${t.name} (${t.isNew ? 'new' : 'changed'})');
    for (final r in t.reasons) {
      b.writeln('• $r');
    }
    b.writeln(t.description.isEmpty ? '(no description)' : t.description);
    if (t.parameters.isNotEmpty) {
      b
        ..writeln('Parameters:')
        ..writeln(t.parameters);
    }
  }
  return (
    message:
        'Code sessions leave these tools of ${s.name} out until you allow them. Read what each one tells the agent, '
        "parameters included, and allow them only if you trust the server: a tool's description or parameters can "
        "carry instructions you don't see in the chat.",
    detail: b.toString().trimRight(),
  );
}
