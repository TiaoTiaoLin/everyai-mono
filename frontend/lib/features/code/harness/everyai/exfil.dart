// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:path/path.dart' as p;

import '../../domain/shell_readonly.dart' show shellSegments;
import 'scrub.dart';

// The tools' own guardrails against carrying secrets off: credential stores
// the agent may not read, commands that print a stored secret, and commands
// that ship data out. They run in front of the tools in every mode, Bypass
// included, and are refused outright (no approval card).
//
// These are rules on command text: a cheap layer that stops the obvious and
// the prompt-injected, not a sandbox. Keep the lists short and practical.

/// The model's text for a refused call: why, that the guard is always on,
/// and to hand the step to the user.
String guardRefusal(String what) =>
    "Error: refused by EveryAI's safety guard: $what. This guard is always on, in every mode. If the user needs "
    'this, tell them what you wanted to send or read and why, and let them do it themselves.';

/// What [path] (absolute, `~` already expanded) holds when it is one of the
/// user's credential stores under [home], or null. Public SSH keys,
/// `known_hosts` and the SSH config stay readable.
String? credentialPath(String path, {required String home}) {
  if (home.isEmpty) return null;
  final p = path.replaceAll('\\', '/');
  final h = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
  if (p != h && !p.startsWith('$h/')) return null;
  final rel = p == h ? '' : p.substring(h.length + 1);
  bool under(String dir) => rel == dir || rel.startsWith('$dir/');
  if (under('.ssh')) {
    final name = rel.split('/').last;
    if (rel != '.ssh' && (name.endsWith('.pub') || name == 'known_hosts' || name == 'config')) return null;
    return 'your SSH keys';
  }
  for (final (dir, what) in _stores) {
    if (under(dir)) return what;
  }
  return null;
}

const _stores = [
  ('.aws', 'your AWS credentials'),
  ('.config/gcloud', 'your Google Cloud credentials'),
  ('.azure', 'your Azure credentials'),
  ('.kube', 'your Kubernetes credentials'),
  ('.docker/config.json', 'your Docker credentials'),
  ('.config/gh/hosts.yml', 'your GitHub CLI token'),
  ('.netrc', 'your saved logins (.netrc)'),
  ('.npmrc', 'your npm token'),
  ('.pypirc', 'your PyPI token'),
  ('.git-credentials', 'your saved Git passwords'),
  ('.gnupg', 'your GPG keys'),
  ('.password-store', 'your password store'),
  ('Library/Keychains', 'your keychain'),
  ('Library/Cookies', "your browser's saved data"),
  ('Library/Safari', "your browser's saved data"),
  ('Library/Application Support/Google/Chrome', "your browser's saved data"),
  ('Library/Application Support/Chromium', "your browser's saved data"),
  ('Library/Application Support/BraveSoftware', "your browser's saved data"),
  ('Library/Application Support/Microsoft Edge', "your browser's saved data"),
  ('Library/Application Support/Arc', "your browser's saved data"),
  ('Library/Application Support/Firefox', "your browser's saved data"),
  ('.mozilla', "your browser's saved data"),
  ('.config/google-chrome', "your browser's saved data"),
  ('.config/chromium', "your browser's saved data"),
  ('.config/BraveSoftware', "your browser's saved data"),
];

/// Sites that take an upload or log a request for whoever made them: paste
/// and file drops, request catchers, out-of-band test servers and tunnels.
/// None is needed to build software, and each is a classic way out.
const dropSites = [
  // Paste and file drops.
  'pastebin.com', 'paste.ee', 'hastebin.com', 'dpaste.org', 'dpaste.com', 'ix.io', 'sprunge.us', 'termbin.com', //
  'paste.rs', '0x0.st', 'rentry.co', 'controlc.com', 'privatebin.net', 'transfer.sh', 'file.io', 'tmpfiles.org',
  'catbox.moe', 'bashupload.com', 'oshi.at', 'gofile.io',
  // Request catchers and out-of-band test servers.
  'webhook.site', 'requestbin.com', 'requestbin.net', 'pipedream.net', 'beeceptor.com', 'hookbin.com',
  'requestcatcher.com', 'interact.sh', 'oast.pro', 'oast.live', 'oast.site', 'oast.online', 'oast.fun', 'oast.me',
  'burpcollaborator.net', 'oastify.com', 'canarytokens.com', 'dnslog.cn', 'ceye.io',
  // Tunnels to someone's machine.
  'ngrok.io', 'ngrok.app', 'ngrok-free.app', 'ngrok-free.dev', 'trycloudflare.com', 'loca.lt', 'localtunnel.me',
  'serveo.net', 'localhost.run', 'lhr.life',
];

/// The drop site [host] belongs to (itself or a subdomain), or null.
String? exfilHost(String host) {
  final h = host.toLowerCase();
  for (final site in dropSites) {
    if (h == site || h.endsWith('.$site')) return site;
  }
  return null;
}

/// What the folder [path] (absolute) holds of the user's credential stores
/// under [home]: a search through it would read them. Null when none lies
/// inside it (or [path] is a store itself: see [credentialPath]).
String? credentialsUnder(String path, {required String home}) {
  if (home.isEmpty) return null;
  final p = _trimSlash(path.replaceAll('\\', '/'));
  final h = _trimSlash(home);
  if (p.isEmpty || h == p || h.startsWith('$p/')) return 'your credential stores';
  if (!p.startsWith('$h/')) return null;
  for (final (dir, what) in [('.ssh', 'your SSH keys'), ..._stores]) {
    if ('$h/$dir'.startsWith('$p/')) return what;
  }
  return null;
}

String _trimSlash(String p) => p.endsWith('/') ? p.substring(0, p.length - 1) : p;

/// Why the shell [command], run in [cwd], would reveal a stored secret, or
/// null: it names one of the user's credential stores (see [credentialPath])
/// for anything but listing or testing it, searches a folder holding them,
/// or runs a command that prints a saved password or token.
String? secretSourceReason(String command, {required String home, String? cwd}) {
  for (final (re, what) in _printers) {
    if (re.hasMatch(command)) return 'the command prints $what';
  }
  // Every mention in the text (redirects included), less the ones in a command that only lists or tests paths. A
  // command the parser won't take apart exempts nothing.
  final mentions = _credentialMentions(command, home);
  final parsed = shellSegments(command);
  var exempt = 0;
  var dir = cwd ?? home;
  for (final words in parsed ?? _roughSegments(command)) {
    final at = _programAt(words);
    if (at >= words.length) continue;
    final program = words[at].split('/').last;
    final args = words.sublist(at + 1);
    if (parsed != null) {
      if (program == 'ssh') {
        // Only the key it logs in with (-i): ssh can also run a command that reads one.
        for (var i = 0; i < args.length; i++) {
          final key = args[i] == '-i' && i + 1 < args.length
              ? args[++i]
              : args[i].startsWith('-i')
              ? args[i].substring(2)
              : null;
          if (key != null) exempt += _credentialMentions(key, home).length;
        }
      } else if (_pathOnly.contains(program)) {
        exempt += _credentialMentions(words.join(' '), home).length;
      }
    }
    // Relative names, from where the shell is (a `cd` earlier in the command moves it).
    if (program == 'cd') {
      final to = args.where((a) => !a.startsWith('-')).firstOrNull;
      dir = to == null ? home : _absolute(to, dir, home);
      continue;
    }
    if (_pathOnly.contains(program) || program == 'ssh') continue;
    // find only lists names unless it runs something on what it finds.
    final searches =
        _searchers.contains(program) &&
        (program != 'find' || args.any((a) => a.startsWith('-exec') || a.startsWith('-ok')));
    for (final a in args) {
      if (a.startsWith('-') || a.contains('://')) continue;
      final abs = _absolute(a, dir, home);
      if (!_mentionStart.hasMatch(a)) {
        if (credentialPath(abs, home: home) case final what?) return 'the command reads $what';
      }
      if (searches) {
        if (credentialsUnder(abs, home: home) case final what?) return 'the command searches $what';
      }
    }
  }
  return mentions.length > exempt ? 'the command reads ${mentions.first}' : null;
}

/// A word that starts with a path [_credentialMentions] already sees.
final _mentionStart = RegExp(r'^(~|\$HOME|\$\{HOME\}|/)');

/// [word] as an absolute path: `~` and `$HOME` expanded, relative ones from [cwd].
String _absolute(String word, String cwd, String home) {
  final w = word.replaceFirst(RegExp(r'^(~|\$HOME|\$\{HOME\})(?=/|$)'), home);
  return p.normalize(p.isAbsolute(w) ? w : p.join(cwd, w));
}

/// Programs that read every file under a folder they are given.
const _searchers = {'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'find', 'tar', 'zip', 'rsync', 'cp', 'scp'};

/// Programs that look at a path without printing what is in it. (`ssh` only
/// for its `-i` key; `scp`, `sftp` and `rsync` copy what is in it.)
const _pathOnly = {'ls', 'test', '[', 'stat', 'chmod', 'ssh-add', 'ssh-keygen'};

/// Commands that print a saved password or token.
final _printers = <(RegExp, String)>[
  (
    RegExp(r'\bsecurity\s+(find-(generic|internet)-password|find-certificate)\b[^;&|\n]*\s-[a-zA-Z]*[wg][a-zA-Z]*\b'),
    'a keychain password',
  ),
  (RegExp(r'\bsecurity\s+(dump-keychain|export)\b'), 'your keychain'),
  (RegExp(r'\bsecret-tool\s+lookup\b'), 'a keyring password'),
  (RegExp(r'\bgh\s+auth\s+(token\b|status\b[^;&|\n]*(--show-token|\s-t\b))'), 'your GitHub token'),
  (RegExp(r'\bgcloud\s+auth\s+(application-default\s+)?print-(access|identity)-token\b'), 'a Google Cloud token'),
  (RegExp(r'\baws\s+configure\s+(export-credentials\b|get\s+\S*(secret|token|key))'), 'your AWS credentials'),
  (RegExp(r'\baws\s+sts\s+get-session-token\b'), 'AWS credentials'),
  (RegExp(r'\baz\s+account\s+get-access-token\b'), 'an Azure token'),
  (RegExp(r'\bop\s+(read\b|item\s+get\b[^;&|\n]*--reveal)'), 'a 1Password secret'),
  (RegExp(r'\bpass\s+show\b'), 'a saved password'),
  (RegExp(r'\bbw\s+get\b'), 'a Bitwarden secret'),
  (RegExp(r'\bgit\s+credential\s+fill\b'), 'a saved Git password'),
  (RegExp(r'\bkubectl\s+config\s+view\b[^;&|\n]*--raw\b'), 'your Kubernetes credentials'),
];

/// The credential stores named in [text]: `~/…`, `$HOME/…`, `${HOME}/…`
/// and absolute paths under [home].
List<String> _credentialMentions(String text, String home) {
  if (home.isEmpty) return const [];
  final h = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
  final re = RegExp('(?:~|\\\$HOME|\\\$\\{HOME\\}|${RegExp.escape(h)})(/[^\\s\'"`;|&<>()]*)?');
  return [for (final m in re.allMatches(text)) ?credentialPath('$h${m.group(1) ?? ''}', home: h)];
}

/// Where the program is in [words]: after any `NAME=value` assignments.
int _programAt(List<String> words) {
  var i = 0;
  while (i < words.length && RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words[i])) {
    i++;
  }
  return i;
}

/// The drop site a host in [text] (a URL, `user@host`) belongs to, or null.
String? dropSiteIn(String text) {
  for (final m in _urlHost.allMatches(text)) {
    if (exfilHost(m.group(1)!) case final site?) return site;
  }
  return null;
}

/// Why the shell [command] would ship data out, or null:
/// - anything naming a drop site (see [dropSites])
/// - curl or wget sending a file, stdin, variables or a secret to a host other than this machine
/// - a URL carrying a secret (see [Scrubber.leak])
/// - `gh gist create`
/// - git push to a remote that wasn't configured when the session started ([pushTargets]: names and URLs;
///   null skips the check), and pointing a remote somewhere new
/// - a lookup whose host name is built from a variable or a command (DNS exfiltration)
String? exfilReason(String command, {required Scrubber scrubber, Set<String>? pushTargets}) {
  if (dropSiteIn(command) case final site?) return 'the command reaches $site, a site that takes uploads';
  if (_builtHost.hasMatch(command) && _network.hasMatch(command)) {
    return 'the command looks up a host name built from a variable or a command, which can carry data out';
  }
  if (RegExp(r'\bgh\s+gist\s+(create|new|edit)\b').hasMatch(command)) return 'the command publishes a gist';
  final parsed = shellSegments(command);
  for (final words in parsed ?? _roughSegments(command)) {
    final at = _programAt(words);
    if (at >= words.length) continue;
    final program = words[at].split('/').last;
    final args = words.sublist(at + 1);
    if (_networkPrograms.contains(program)) {
      for (final a in args) {
        if (a.startsWith('-')) continue;
        if (exfilHost(_hostOf(a)) case final site?) return 'the command reaches $site, a site that takes uploads';
      }
    }
    switch (program) {
      case 'curl' || 'wget':
        if (_upload(program, args, scrubber, parsed == null) case final what?) return what;
      case 'git':
        if (words.take(at).any((w) => w.startsWith('GIT_CONFIG_'))) {
          return 'the command sets git configuration from the environment, which can point a push somewhere new';
        }
        if (_push(args, pushTargets) case final what?) return what;
    }
  }
  return null;
}

/// The host of a URL or a bare `host[:port][/path]` word.
String _hostOf(String word) => Uri.tryParse(word.contains('://') ? word : 'http://$word')?.host ?? '';

/// A host after `://` or `user@`.
final _urlHost = RegExp(r'(?:://|@)((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})');

const _networkPrograms = {'curl', 'wget', 'nc', 'ncat', 'netcat', 'socat', 'telnet', 'ssh', 'scp', 'sftp', 'rsync'};

/// A host name with a variable or command in front of a domain: `$X.evil.com`, `"$(whoami)".evil.com`.
final _builtHost = RegExp(
  r'''(?<=^|[\s'"@=]|//)(\$\{?\w+\}?|\$\([^)]*\)|`[^`]*`)['"]?[\w.-]*\.[A-Za-z0-9-]+\.[A-Za-z]{2,}\b''',
);

final _network = RegExp(r'\b(curl|wget|nslookup|dig|host|drill|ping|nc|ncat|resolvectl)\b');

/// The command split at `;`, `&`, `|` and newlines, then at spaces, with quotes and parentheses dropped: a rough look
/// at a command [shellSegments] won't take apart (output to a file, `$(…)`). A backtick becomes `$`, so a word with a
/// substitution in it still shows one.
List<List<String>> _roughSegments(String command) => [
  for (final part in command.split(RegExp(r'&&|\|\||[;&|\n]')))
    [
      for (final w in part.replaceAll('`', r'$').replaceAll(RegExp('["\'()]'), ' ').split(RegExp(r'\s+')))
        if (w.isNotEmpty) w,
    ],
];

/// curl and wget options that send a body: the value is data (`-d x`, `-d @file`), a file, or a form field.
const _curlData = {'-d', '--data', '--data-raw', '--data-binary', '--data-urlencode', '--data-ascii', '--json'};
const _curlForm = {'-F', '--form', '--form-string'};
const _curlFile = {'-T', '--upload-file'};
const _wgetData = {'--post-data', '--body-data'};
const _wgetFile = {'--post-file', '--body-file'};

/// Options whose value is the next word and isn't a URL or data.
const _valued = {
  '-o', '--output', '-O', '--output-document', '-X', '--request', '-A', '--user-agent', '-c', '--cookie-jar', //
  '-w', '--write-out', '-m', '--max-time', '--connect-timeout', '-P', '--directory-prefix', '--header-file',
};

/// Options whose value goes to the server with the request: a header, a login, a cookie, the referrer.
const _sentValued = {'-H', '--header', '-u', '--user', '-b', '--cookie', '-e', '--referer', '--oauth2-bearer'};

/// Options whose value is a host the request goes through or to.
const _hostValued = {'-x', '--proxy', '--preproxy', '--connect-to', '--resolve', '-e', '--execute'};

/// A `$NAME`, `${NAME}`, `$(…)` or backtick: a value the shell fills in, which the text rules can't see.
final _expands = RegExp(r'\$[A-Za-z_{(]|`');

/// Why curl or wget with [args] uploads something it shouldn't, or null.
/// [rough] when the words come from [_roughSegments] (substitutions were
/// there): any data then counts as unknown. A request to this machine only
/// is never refused.
String? _upload(String program, List<String> args, Scrubber scrubber, bool rough) {
  final hosts = <String>[];
  final urls = <String>[];
  final sent = <(String, String)>[]; // (kind: data|form|file|header, value)
  final kinds = program == 'curl'
      ? {'data': _curlData, 'form': _curlForm, 'file': _curlFile}
      : {'data': _wgetData, 'file': _wgetFile};
  // `-x host`, `--proxy=host`: the value of option [f] in args[i], or null.
  String? valueOf(String f, int i) {
    final a = args[i];
    if (a == f) return i + 1 < args.length ? args[i + 1] : '';
    if (a.startsWith('$f=')) return a.substring(f.length + 1);
    if (f.length == 2 && !f.startsWith('--') && a.length > 2 && a.startsWith(f)) return a.substring(2);
    return null;
  }

  words:
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    for (final MapEntry(key: kind, value: flags) in kinds.entries) {
      for (final f in flags) {
        if (valueOf(f, i) case final v?) {
          if (a == f) i++;
          sent.add((kind, v));
          continue words;
        }
      }
    }
    for (final f in {..._sentValued, ..._hostValued}) {
      if (valueOf(f, i) case final v?) {
        if (a == f) i++;
        // wget's -e runs a .wgetrc command (`-e use_proxy=on -e http_proxy=…`); curl's is the referrer.
        if (_hostValued.contains(f) && !(program == 'curl' && f == '-e')) {
          // A proxy URL, or `host:port:address` (--resolve, --connect-to), or `http_proxy=URL` (wget -e).
          final value = v.contains('=') ? v.substring(v.indexOf('=') + 1) : v;
          for (final h in {_hostOf(value), for (final part in value.split(RegExp('[:,]'))) _hostOf(part)}) {
            if (h.contains('.') || h == 'localhost') hosts.add(h);
          }
        }
        if (_sentValued.contains(f) && !(program == 'wget' && f == '-e')) sent.add(('header', v));
        continue words;
      }
    }
    if (_valued.contains(a)) {
      i++;
    } else if (!a.startsWith('-')) {
      urls.add(a);
      if (_hostOf(a) case final h when h.isNotEmpty) hosts.add(h);
    }
  }
  if (hosts.isNotEmpty && hosts.every(_loopback)) return null;
  for (final u in urls) {
    if (scrubber.leak(u) case final what?) return 'the URL carries $what';
    if (u.contains(r'$')) return 'the URL carries the value of a variable or command to another computer';
  }
  for (final (kind, v) in sent) {
    final at = switch (kind) {
      'file' => 0,
      'data' => v.indexOf(RegExp('^@')),
      'form' => v.indexOf(RegExp('=[@<]')),
      _ => -1,
    };
    if (at >= 0) {
      final file = v.substring(kind == 'file' ? 0 : v.indexOf(RegExp('[@<]'), at) + 1);
      return 'the command uploads ${file == '-' || file.isEmpty ? 'its input' : file} to another computer';
    }
    if (scrubber.leak(v) case final what?) return 'the command sends $what to another computer';
    if (rough || _expands.hasMatch(v)) {
      return 'the command sends the value of a variable or command to another computer';
    }
  }
  return null;
}

/// This machine: `localhost`, `*.localhost`, a 127.x.x.x or `::1` address, or `0.0.0.0`. A name that only starts
/// with `127.` is somewhere else.
bool _loopback(String host) {
  final h = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  return h == 'localhost' ||
      h.endsWith('.localhost') ||
      h == '::1' ||
      h == '0.0.0.0' ||
      RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(h);
}

/// Why `git` with [args] pushes somewhere new, or null.
String? _push(List<String> args, Set<String>? targets) {
  // Global options before the subcommand: -C dir, -c key=value (which can set a push address for this run).
  var i = 0;
  while (i < args.length && args[i].startsWith('-')) {
    final config = args[i] == '-c'
        ? (i + 1 < args.length ? args[i + 1] : '')
        : args[i].startsWith('--config-env=')
        ? args[i].substring(13)
        : null;
    if (config != null && _addressKey(config.split('=').first)) {
      return 'the command points a remote at a new address';
    }
    i += args[i] == '-C' || args[i] == '-c' ? 2 : 1;
  }
  if (i >= args.length) return null;
  final sub = args[i];
  final rest = args.sublist(i + 1);
  if (sub == 'remote' && rest.isNotEmpty && rest.first == 'set-url') {
    return 'the command points a remote at a new address';
  }
  if (sub == 'config' && _addressKey(_configWrite(rest) ?? '')) {
    return 'the command points a remote at a new address';
  }
  if (sub != 'push' || targets == null) return null;
  String? remote;
  for (var j = 0; j < rest.length; j++) {
    final a = rest[j];
    if (a.startsWith('--repo=')) {
      remote = a.substring(7);
      break;
    }
    if (a == '--repo' && j + 1 < rest.length) {
      remote = rest[j + 1];
      break;
    }
    if (a.startsWith('-')) {
      // Options that take a value as the next word.
      if (const {'-o', '--push-option', '--receive-pack', '--exec'}.contains(a)) j++;
      continue;
    }
    remote = a;
    break;
  }
  if (remote == null || targets.contains(remote)) return null;
  return 'the command pushes to $remote, which was not one of this repository\'s remotes when the session started';
}

/// Whether the git config [key] says where a push goes: a remote's address, the default push remote, a branch's
/// remote, or a URL rewrite.
bool _addressKey(String key) {
  final k = key.toLowerCase();
  return RegExp(r'^remote\..+\.(url|pushurl)$').hasMatch(k) ||
      k == 'remote.pushdefault' ||
      RegExp(r'^branch\..+\.(remote|pushremote)$').hasMatch(k) ||
      RegExp(r'^url\..+\.(insteadof|pushinsteadof)$').hasMatch(k);
}

/// The key `git config` with [args] writes, or null when it only reads (`--get`, `--list`, a key alone).
String? _configWrite(List<String> args) {
  final words = [for (final a in args) a];
  const reads = {'get', 'list', '--get', '--get-all', '--get-regexp', '--list', '-l', '--show-origin'};
  if (words.any(reads.contains)) return null;
  // `git config set key value` (git 2.46+) and `git config [--add|--replace-all] key value`.
  final plain = [
    for (final w in words)
      if (!w.startsWith('-') && w != 'set' && w != 'unset') w,
  ];
  if (plain.length >= 2) return plain.first;
  return null;
}
