// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// Whether a terminal command only looks at the workspace, so Ask and Plan
/// mode can run it without asking.
///
/// The command is split the way a shell would (quotes, `&&`, `||`, `;`, `|`)
/// and every part must be a known reader: `cd`, `ls`, `cat`, `rg`, `find`
/// without `-exec`/`-delete`, `sed` without `-i`, `git log`/`diff`/`status`
/// and friends. Output may only be redirected to `/dev/null` or another fd.
/// Anything the parser can't vouch for (command substitution, subshells,
/// heredocs, backgrounding, unknown programs) counts as a change.
bool isReadOnlyShell(String command) {
  if (command.trim().isEmpty) return false;
  final segments = _parse(command);
  if (segments == null || segments.isEmpty) return false;
  return segments.every(_segmentReadOnly);
}

/// The words of each simple command in [command] (split at `&&`, `||`, `;`,
/// `|` and newlines, quotes removed), or null when it does something a
/// word list can't describe: command substitution, subshells, heredocs,
/// backgrounding, or output redirected to a file.
List<List<String>>? shellSegments(String command) => command.trim().isEmpty ? null : _parse(command);

/// The words of each simple command, or null when the command does something
/// the classifier won't reason about.
List<List<String>>? _parse(String s) {
  final segments = <List<String>>[];
  var words = <String>[];
  final word = StringBuffer();
  var inWord = false;

  void endWord() {
    if (!inWord) return;
    words.add(word.toString());
    word.clear();
    inWord = false;
  }

  void endSegment() {
    endWord();
    if (words.isNotEmpty) segments.add(words);
    words = <String>[];
  }

  var i = 0;
  while (i < s.length) {
    final c = s[i];
    switch (c) {
      case "'":
        final end = s.indexOf("'", i + 1);
        if (end < 0) return null;
        word.write(s.substring(i + 1, end));
        inWord = true;
        i = end + 1;
      case '"':
        var j = i + 1;
        while (j < s.length && s[j] != '"') {
          if (s[j] == r'\' && j + 1 < s.length) {
            word.write(s[j + 1]);
            j += 2;
            continue;
          }
          if (s[j] == '`' || s.startsWith(r'$(', j)) return null;
          word.write(s[j]);
          j++;
        }
        if (j >= s.length) return null;
        inWord = true;
        i = j + 1;
      case r'\':
        if (i + 1 < s.length && s[i + 1] != '\n') {
          word.write(s[i + 1]);
          inWord = true;
        }
        i += 2;
      case '`' || '(' || ')':
        return null;
      case r'$' when s.startsWith(r'$(', i):
        return null;
      case ' ' || '\t':
        endWord();
        i++;
      case '\n' || ';':
        endSegment();
        i++;
      case '&':
        if (s.startsWith('&&', i)) {
          endSegment();
          i += 2;
        } else if (s.startsWith('&>', i)) {
          endWord();
          final target = _target(s, s.startsWith('&>>', i) ? i + 3 : i + 2);
          if (target == null || target.$1 != '/dev/null') return null;
          i = target.$2;
        } else {
          // Backgrounding.
          return null;
        }
      case '|':
        endSegment();
        i += s.startsWith('||', i) || s.startsWith('|&', i) ? 2 : 1;
      case '<':
        if (s.startsWith('<<', i) || s.startsWith('<(', i)) return null;
        if (_dropFd(word, inWord)) {
          inWord = false;
        } else {
          endWord();
        }
        // Reading a file is fine; the file name isn't an argument.
        final target = _target(s, i + 1);
        if (target == null) return null;
        i = target.$2;
      case '>':
        if (_dropFd(word, inWord)) {
          inWord = false;
        } else {
          endWord();
        }
        var j = i + 1;
        if (j < s.length && s[j] == '>') j++;
        if (j < s.length && s[j] == '&') {
          // An fd dup: 2>&1, >&2, 2>&-.
          j++;
          final start = j;
          while (j < s.length && RegExp(r'[0-9-]').hasMatch(s[j])) {
            j++;
          }
          if (j == start) return null;
          i = j;
        } else {
          if (j < s.length && (s[j] == '|' || s[j] == '(')) return null;
          final target = _target(s, j);
          if (target == null || target.$1 != '/dev/null') return null;
          i = target.$2;
        }
      default:
        word.write(c);
        inWord = true;
        i++;
    }
  }
  endSegment();
  return segments;
}

/// `2>` and `2<`: the digits before the arrow name an fd, not a word.
bool _dropFd(StringBuffer word, bool inWord) {
  if (!inWord || !RegExp(r'^[0-9]+$').hasMatch(word.toString())) return false;
  word.clear();
  return true;
}

/// The redirection target starting at [i] (after spaces) and the index after it.
(String, int)? _target(String s, int i) {
  while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
    i++;
  }
  final b = StringBuffer();
  while (i < s.length && !' \t\n;&|<>()'.contains(s[i])) {
    final c = s[i];
    if (c == "'" || c == '"') {
      final end = s.indexOf(c, i + 1);
      if (end < 0) return null;
      b.write(s.substring(i + 1, end));
      i = end + 1;
      continue;
    }
    // A computed target could be anything.
    if (c == '`' || c == r'$') return null;
    b.write(c);
    i++;
  }
  return b.isEmpty ? null : (b.toString(), i);
}

/// Programs that only print what they read (no flags that write or run).
const _readers = {
  'ls', 'cat', 'head', 'tail', 'wc', 'grep', 'egrep', 'fgrep', 'tree', 'stat', 'file', 'which', 'whereis', //
  'type', 'pwd', 'echo', 'printf', 'sort', 'uniq', 'cut', 'tr', 'nl', 'jq', 'yq', 'du', 'df', 'basename',
  'dirname', 'realpath', 'readlink', 'date', 'uname', 'whoami', 'id', 'hostname', 'diff', 'cmp', 'comm',
  'column', 'fold', 'od', 'xxd', 'hexdump', 'strings', 'sha256sum', 'shasum', 'md5', 'md5sum', 'true',
  'false', 'test', '[', 'cd', 'pushd', 'popd', 'sleep', 'printenv', 'bat', 'eza', 'exa', 'fd', 'rg', 'ag',
  'locate', 'command', 'expr', 'seq', 'rev', 'paste', 'join', 'look', 'tac', 'ldd', 'otool', 'nm', 'lipo',
};

/// Flags that make an otherwise read-only program write or run something.
/// One-letter flags also count inside a group (`-uo`).
const _writingFlags = {
  'sort': {'-o', '--output'},
  'tree': {'-o'},
  'rg': {'--pre'},
  'fd': {'-x', '--exec', '-X', '--exec-batch'},
  'yq': {'-i', '--inplace'},
};

bool _hasWritingFlag(List<String> args, Set<String> flags) => args.any(
  (a) => flags.any(
    (f) =>
        a == f ||
        a.startsWith('$f=') ||
        (f.length == 2 && !a.startsWith('--') && RegExp('^-[a-zA-Z]*${f[1]}').hasMatch(a)),
  ),
);

/// `xxd` options that take a value.
const _xxdValued = {'-c', '-cols', '-g', '-groupsize', '-l', '-len', '-o', '-offset', '-s', '-seek', '-n', '-name'};

/// Environment assignments that can't make a reader run anything: locale,
/// colour and terminal size, and a pager that is `cat` or nothing. Anything
/// else (`GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `LD_PRELOAD`, ...) may run code.
bool _safeAssignment(String word) {
  final eq = word.indexOf('=');
  final name = word.substring(0, eq);
  final value = word.substring(eq + 1);
  if (const {'GIT_PAGER', 'PAGER', 'MANPAGER'}.contains(name)) return value.isEmpty || value == 'cat';
  return const {
        'LANG', 'LANGUAGE', 'TZ', 'NO_COLOR', 'FORCE_COLOR', 'CLICOLOR', 'CLICOLOR_FORCE', 'COLUMNS', 'LINES', //
        'TERM', 'GREP_COLOR', 'GREP_COLORS', 'LS_COLORS', 'LSCOLORS',
      }.contains(name) ||
      name.startsWith('LC_');
}

/// Toolchains whose `--version` is harmless.
const _versioned = {
  'node', 'python', 'python3', 'dart', 'flutter', 'go', 'cargo', 'rustc', 'npm', 'pnpm', 'yarn', 'bun', //
  'java', 'zig', 'ruby', 'swift', 'gcc', 'clang', 'make', 'cmake', 'deno', 'uv', 'pip', 'pip3', 'git', 'gh',
};

bool _segmentReadOnly(List<String> words) {
  var w = words;
  // FOO=bar prefixes, only harmless ones.
  while (w.isNotEmpty && RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(w.first)) {
    if (!_safeAssignment(w.first)) return false;
    w = w.sublist(1);
  }
  if (w.isEmpty) return true;
  var cmd = w.first;
  for (final dir in const ['/usr/bin/', '/bin/', '/usr/local/bin/', '/opt/homebrew/bin/']) {
    if (cmd.startsWith(dir)) cmd = cmd.substring(dir.length);
  }
  final args = w.sublist(1);

  if (_versioned.contains(cmd) && args.length == 1 && const {'--version', '-v', '-V', 'version'}.contains(args[0])) {
    return true;
  }
  if (_readers.contains(cmd)) {
    final bad = _writingFlags[cmd];
    if (bad != null && _hasWritingFlag(args, bad)) return false;
    // `uniq in out` writes out.
    if (cmd == 'uniq' && args.where((a) => !a.startsWith('-')).length > 1) return false;
    // So do `xxd in out` and `xxd -r hex out`.
    if (cmd == 'xxd') {
      var positionals = 0;
      for (var i = 0; i < args.length; i++) {
        if (_xxdValued.contains(args[i])) {
          i++;
        } else if (args[i] == '-' || !args[i].startsWith('-')) {
          positionals++;
        }
      }
      if (positionals > 1) return false;
    }
    // `command foo` runs foo; only `command -v`/`-V` look it up.
    if (cmd == 'command' && !(args.isNotEmpty && (args[0] == '-v' || args[0] == '-V'))) return false;
    return true;
  }
  return switch (cmd) {
    'find' => !args.any(
      (a) => const {
        '-exec',
        '-execdir',
        '-ok',
        '-okdir',
        '-delete',
        '-fprint',
        '-fprint0',
        '-fprintf',
        '-fls',
      }.contains(a),
    ),
    'sed' || 'gsed' => _sedReadOnly(args),
    'awk' || 'gawk' || 'nawk' => _awkReadOnly(args),
    'xargs' => _xargsReadOnly(args),
    'timeout' => args.length >= 2 && _segmentReadOnly(args.sublist(1)),
    'env' => args.every((a) => a.startsWith('-') && a != '-S' && a != '--split-string'),
    'git' => _gitReadOnly(args),
    'gh' => _ghReadOnly(args),
    'dart' || 'flutter' => args.length >= 2 && args[0] == 'pub' && (args[1] == 'deps' || args[1] == 'outdated'),
    'npm' || 'pnpm' => args.isNotEmpty && const {'ls', 'list', 'view', 'outdated', 'why', 'explain'}.contains(args[0]),
    'yarn' => args.isNotEmpty && const {'list', 'info', 'why', 'outdated'}.contains(args[0]),
    'pip' || 'pip3' => args.isNotEmpty && const {'list', 'show', 'freeze'}.contains(args[0]),
    'cargo' => args.isNotEmpty && const {'tree', 'metadata'}.contains(args[0]),
    'go' => args.isNotEmpty && const {'list', 'env', 'version', 'doc'}.contains(args[0]),
    _ => false,
  };
}

bool _sedReadOnly(List<String> args) {
  for (final a in args) {
    if (a.startsWith('--in-place')) return false;
    // -i, -i.bak, and combined short flags such as -ni.
    if (RegExp(r'^-[a-zA-Z]*i').hasMatch(a) && !a.startsWith('--')) return false;
    // The w/W (write) and e (execute) commands, and the s///w flag.
    if (!a.startsWith('-') && RegExp(r'(^|[;{}\s]|\d)[wWe]\s|/w\s').hasMatch(a)) return false;
  }
  return true;
}

bool _awkReadOnly(List<String> args) => !args.any(
  (a) =>
      a.contains('system(') ||
      a.contains('getline') ||
      a.contains('|&') ||
      RegExp(r'printf?\b[^;}]*(>|\|)').hasMatch(a) ||
      a.startsWith('-i'),
);

bool _xargsReadOnly(List<String> args) {
  // Options that take a value.
  const valued = {'-n', '-I', '-L', '-P', '-d', '-s', '-E', '-J', '-R', '-S'};
  var i = 0;
  while (i < args.length && args[i].startsWith('-')) {
    i += valued.contains(args[i]) ? 2 : 1;
  }
  // Without a command xargs runs echo.
  return i >= args.length || _segmentReadOnly(args.sublist(i));
}

bool _gitReadOnly(List<String> args) {
  var i = 0;
  // Global options.
  while (i < args.length && args[i].startsWith('-')) {
    final a = args[i];
    if (a == '-C') {
      i += 2;
    } else if (a == '--no-pager' || a.startsWith('--git-dir=') || a.startsWith('--work-tree=') || a == '-P') {
      i++;
    } else {
      // -c can set an alias or pager to any program.
      return false;
    }
  }
  if (i >= args.length) return true;
  final sub = args[i];
  final rest = args.sublist(i + 1);
  bool has(Set<String> flags) => rest.any((a) => flags.any((f) => a == f || a.startsWith('$f=')));
  final positionals = rest.where((a) => !a.startsWith('-')).toList();
  // Options that write a file or run a program.
  const runs = {'--output', '--ext-diff', '--textconv'};
  return switch (sub) {
    // `-O<cmd>` opens the matches with any program.
    'grep' =>
      !has({...runs, '--open-files-in-pager'}) &&
          !rest.any((a) => !a.startsWith('--') && RegExp(r'^-[a-zA-Z]*O').hasMatch(a)),
    'status' || 'show' || 'ls-files' || 'ls-tree' || 'blame' || 'shortlog' || 'describe' => !has(runs),
    'log' || 'diff' || 'rev-list' || 'whatchanged' || 'range-diff' => !has(runs),
    'cat-file' => !has({...runs, '--filters'}),
    'rev-parse' || 'merge-base' || 'name-rev' || 'show-ref' || 'for-each-ref' => true,
    'count-objects' || 'check-ignore' || 'var' || 'help' || 'version' => true,
    'branch' =>
      !has({
            '-d', '-D', '--delete', '-m', '-M', '--move', '-c', '-C', '--copy', '-u', '--set-upstream-to', //
            '--unset-upstream', '--edit-description', '-f', '--force',
          }) &&
          (positionals.isEmpty ||
              has({'--list', '-l', '--contains', '--no-contains', '--merged', '--no-merged', '--points-at'})),
    'tag' => positionals.isEmpty || has({'-l', '--list', '--contains', '--points-at', '--merged', '--no-merged'}),
    'remote' => positionals.isEmpty || const {'show', 'get-url'}.contains(positionals.first),
    'stash' => positionals.isNotEmpty && const {'list', 'show'}.contains(positionals.first),
    'worktree' => positionals.isNotEmpty && positionals.first == 'list',
    'reflog' => positionals.isEmpty || positionals.first == 'show',
    // Lists a remote's refs; --upload-pack would run a program.
    'ls-remote' => !has({'--upload-pack', '-u'}),
    'config' => has({'--get', '--get-all', '--get-regexp', '--list', '-l', '--show-origin'}),
    _ => false,
  };
}

/// `gh` commands that only read from GitHub: viewing and listing issues,
/// pull requests, runs, releases and repositories, searching, and `gh api`
/// GET requests. Anything that opens a browser, checks out, downloads or
/// sends data is not.
bool _ghReadOnly(List<String> args) {
  if (args.isEmpty) return false;
  final sub = args[0];
  final rest = args.sublist(1);
  final positionals = rest.where((a) => !a.startsWith('-')).toList();
  final verb = positionals.firstOrNull ?? '';
  bool has(Set<String> flags) => rest.any((a) => flags.any((f) => a == f || a.startsWith('$f=')));
  if (has({'--web', '-w'})) return false;
  return switch (sub) {
    'issue' => const {'view', 'list', 'status'}.contains(verb),
    'pr' => const {'view', 'list', 'diff', 'checks', 'status'}.contains(verb),
    'repo' || 'release' || 'gist' || 'workflow' => const {'view', 'list'}.contains(verb),
    'run' => const {'view', 'list'}.contains(verb),
    'label' || 'ruleset' || 'cache' || 'variable' => verb == 'list',
    'search' => const {'repos', 'issues', 'prs', 'code', 'commits'}.contains(verb),
    'auth' => verb == 'status',
    'status' => true,
    'api' => _ghApiGet(rest),
    _ => false,
  };
}

/// `gh api` that stays a GET: no method other than GET/HEAD, no fields or
/// input (which make it a POST), and not GraphQL (which can mutate).
bool _ghApiGet(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == 'graphql' || a.contains('/graphql')) return false;
    if (const {'-f', '-F', '--field', '--raw-field', '--input'}.any((f) => a == f || a.startsWith('$f='))) {
      return false;
    }
    if (a == '-X' || a == '--method') {
      final m = i + 1 < args.length ? args[i + 1].toUpperCase() : '';
      if (m != 'GET' && m != 'HEAD') return false;
      i++;
    } else if (a.startsWith('--method=') || (a.startsWith('-X') && a.length > 2)) {
      final m = (a.startsWith('--method=') ? a.substring(9) : a.substring(2)).toUpperCase();
      if (m != 'GET' && m != 'HEAD') return false;
    }
  }
  return true;
}

/// Whether [command] is fit for planning: [isReadOnlyShell], or it looks
/// things up without changing the project: `git fetch` and `git pull
/// --ff-only` (getting main up to date), `curl`/`wget` printing a page,
/// and inspecting packages and tools (`npm search`, `brew info`, `docker
/// ps`, `--help`). Max/Ultra phases before the plan, and Plan mode (where
/// what isn't read-only still asks), allow these.
bool isPlanningShell(String command) {
  if (command.trim().isEmpty) return false;
  final segments = _parse(command);
  if (segments == null || segments.isEmpty) return false;
  return segments.every((w) => _segmentReadOnly(w) || _segmentPlanning(w));
}

/// Tools whose `--help`, `-h` or `help` (with a subcommand) is harmless.
const _helped = {
  ..._versioned, 'docker', 'kubectl', 'brew', 'curl', 'wget', 'xcodebuild', 'xcrun', 'adb', 'terraform', 'gradle', //
  'mvn', 'poetry', 'gem', 'bundle', 'composer', 'rustup', 'pod', 'helm', 'aws', 'gcloud', 'az', 'vercel', 'netlify',
};

bool _segmentPlanning(List<String> words) {
  var w = words;
  while (w.isNotEmpty && RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(w.first)) {
    if (!_safeAssignment(w.first)) return false;
    w = w.sublist(1);
  }
  if (w.isEmpty) return true;
  final cmd = w.first;
  final args = w.sublist(1);
  final verb = args.where((a) => !a.startsWith('-')).firstOrNull ?? '';
  // `tool --help`, `tool sub --help`, `tool help sub`.
  if (_helped.contains(cmd) &&
      args.isNotEmpty &&
      (const {'--help', '-h'}.contains(args.last) || args.first == 'help') &&
      args.length <= 3) {
    return true;
  }
  return switch (cmd) {
    'git' => _gitPlanning(args),
    'curl' => _curlPrints(args),
    'wget' => _wgetPrints(args),
    'npm' || 'pnpm' =>
      const {'search', 'info', 'view', 'ping'}.contains(verb) ||
          (verb == 'config' && args.length >= 2 && const {'get', 'list', 'ls'}.contains(args[1])),
    'yarn' => const {'info', 'npm'}.contains(verb) && !args.contains('publish'),
    'pip' || 'pip3' => verb == 'index' || verb == 'search',
    'uv' => args.length >= 2 && args[0] == 'pip' && const {'list', 'show', 'tree'}.contains(args[1]) || verb == 'tree',
    'poetry' => const {'show', 'check'}.contains(verb),
    'cargo' => const {'search', 'info', 'tree', 'metadata'}.contains(verb),
    'gem' => const {'list', 'info', 'search', 'specification'}.contains(verb),
    'bundle' => const {'list', 'info', 'outdated'}.contains(verb),
    'composer' => const {'show', 'outdated', 'depends', 'why'}.contains(verb),
    'brew' => const {'info', 'list', 'search', 'deps', 'uses', 'outdated', 'config', 'desc', 'leaves'}.contains(verb),
    'docker' =>
      const {'ps', 'images', 'inspect', 'logs', 'version', 'info', 'top', 'port'}.contains(verb) ||
          (verb == 'compose' && args.length >= 2 && const {'ps', 'config', 'logs', 'ls', 'images'}.contains(args[1])),
    'kubectl' => const {'get', 'describe', 'logs', 'version', 'explain', 'api-resources', 'top'}.contains(verb),
    'flutter' => const {'doctor', 'devices', 'emulators'}.contains(verb),
    'xcodebuild' => args.isNotEmpty && args.every((a) => const {'-list', '-version', '-showsdks', '-json'}.contains(a)),
    'xcrun' => args.length >= 2 && args[0] == 'simctl' && args[1] == 'list',
    'adb' => verb == 'devices',
    'rustup' => const {'show', 'toolchain'}.contains(verb) && !args.contains('install'),
    'ps' || 'lsof' || 'netstat' || 'man' || 'tldr' || 'apropos' || 'sw_vers' || 'nproc' || 'uptime' => true,
    'dig' || 'nslookup' || 'host' => !args.contains('-f'),
    _ => false,
  };
}

/// `git fetch` (any remote or refspec, e.g. `git fetch origin main:main`),
/// `git remote update`, and `git pull --ff-only` (a fast-forward of upstream
/// work only). `--upload-pack` would run a program.
bool _gitPlanning(List<String> args) {
  var i = 0;
  while (i < args.length && args[i].startsWith('-')) {
    if (args[i] == '-C') {
      i += 2;
    } else if (args[i] == '--no-pager') {
      i++;
    } else {
      return false;
    }
  }
  if (i >= args.length) return false;
  final sub = args[i];
  final rest = args.sublist(i + 1);
  if (rest.any((a) => a.startsWith('--upload-pack') || a == '-u' || a.startsWith('--exec'))) return false;
  return switch (sub) {
    'fetch' => true,
    'remote' => rest.isNotEmpty && rest.first == 'update',
    'pull' => rest.contains('--ff-only') && !rest.any((a) => a == '--rebase' || a.startsWith('--rebase=') || a == '-r'),
    _ => false,
  };
}

/// `curl` that only prints what it gets: no output files, uploads, data,
/// forms, config files, cookie jars, or methods other than GET/HEAD.
bool _curlPrints(List<String> args) {
  const longBad = {
    '--output', '--remote-name', '--remote-name-all', '--upload-file', '--data', '--data-raw', '--data-binary', //
    '--data-urlencode', '--data-ascii', '--form', '--form-string', '--json', '--config', '--cookie-jar',
    '--output-dir', '--create-dirs', '--trace', '--trace-ascii', '--libcurl', '--etag-save', '--hsts', '--alt-svc',
  };
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--')) {
      final name = a.split('=').first;
      if (longBad.contains(name)) return false;
      if (name == '--request') {
        final m = (a.contains('=') ? a.split('=')[1] : (i + 1 < args.length ? args[++i] : '')).toUpperCase();
        if (m != 'GET' && m != 'HEAD') return false;
      }
      if (name == '--dump-header' &&
          (a.contains('=') ? a.split('=')[1] : (i + 1 < args.length ? args[i + 1] : '')) != '-') {
        return false;
      }
      continue;
    }
    if (a.startsWith('-') && a.length > 1) {
      final flags = a.substring(1);
      // -o, -O, -T, -d, -F, -K, -c write or send something.
      if (RegExp('[oOTdFKc]').hasMatch(flags)) return false;
      if (flags.contains('X')) {
        final after = flags.substring(flags.indexOf('X') + 1);
        final m = (after.isNotEmpty ? after : (i + 1 < args.length ? args[++i] : '')).toUpperCase();
        if (m != 'GET' && m != 'HEAD') return false;
      }
      if (flags.endsWith('D') && (i + 1 >= args.length || args[i + 1] != '-')) return false;
    }
  }
  return true;
}

/// `wget` writing the page to stdout (`-O -`, `-qO-`, `--output-document=-`)
/// and nothing else to disk.
bool _wgetPrints(List<String> args) {
  var toStdout = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--output-document=-' || a == '-O-' || RegExp(r'^-[a-zA-Z]*O-$').hasMatch(a)) {
      toStdout = true;
    } else if ((a == '-O' || RegExp(r'^-[a-zA-Z]*O$').hasMatch(a)) && i + 1 < args.length && args[i + 1] == '-') {
      toStdout = true;
      i++;
    } else if (a.startsWith('--post') ||
        a.startsWith('--body') ||
        a == '-i' ||
        a.startsWith('--input-file') ||
        a.startsWith('-r') ||
        a.startsWith('--recursive') ||
        a.startsWith('-m') ||
        a.startsWith('--mirror') ||
        a.startsWith('-o') ||
        a.startsWith('-a') ||
        a.startsWith('--method') ||
        a.startsWith('-P') ||
        a.startsWith('--directory-prefix') ||
        a.startsWith('-x') ||
        a.startsWith('--save-')) {
      return false;
    }
  }
  return toStdout;
}
