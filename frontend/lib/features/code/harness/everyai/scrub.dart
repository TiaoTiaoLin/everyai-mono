// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

export 'research_sites.dart';

/// Finds secrets in what an agent is about to send out (a fetched URL, a
/// search query), so a prompt-injected page can't have them carried off, and
/// hides them in what the tools hand the model ([redact]).
/// Looks for the values of secret-named environment variables (the app's and
/// the login shell's, see [addEnv]), values from the project's `.env*` files
/// and other secret files the agent read ([remember]), the gateway key, and
/// well-known key shapes.
final class Scrubber {
  Scrubber({Map<String, String> env = const {}, Iterable<String> values = const []}) {
    addEnv(env);
    remember(values);
  }

  /// The user's environment and the `.env*` files in [projectDir], plus [extra]
  /// (the gateway key).
  factory Scrubber.forProject(String projectDir, {Iterable<String> extra = const []}) =>
      Scrubber(env: Platform.environment, values: [...extra, ...dotEnvValues(projectDir)]);

  final _values = <String>{};

  /// Adds the secret-named values of [env] (a login shell's environment
  /// holds keys exported in `.zshrc` that the app's own doesn't).
  void addEnv(Map<String, String> env) {
    for (final MapEntry(:key, :value) in env.entries) {
      if (secretName(key)) remember([value]);
    }
  }

  /// Adds [values] (read from a secret file). Short ones, paths, phrases,
  /// numbers and email addresses would hide ordinary text, so they are left
  /// out.
  void remember(Iterable<String> values) {
    for (final v in values.map((v) => v.trim())) {
      if (v.length >= 8 && !v.startsWith('/') && !v.contains(' ') && !_plainValue(v)) _values.add(v);
    }
  }

  /// Whether a value is a number, an email address or a yes/no word: not a secret, whatever its name says.
  static bool _plainValue(String v) =>
      RegExp(r'^[0-9.,_:-]+$').hasMatch(v) ||
      RegExp(r'^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$').hasMatch(v) ||
      const {'true', 'false', 'yes', 'no', 'enabled', 'disabled'}.contains(v.toLowerCase());

  /// Whether the variable [name] holds a secret: one of its `_`-separated parts is a secret word (`API_KEY`,
  /// `GH_TOKEN`, `npm_config__authToken`), so `AUTHOR`, `KEYBOARD` and `MAX_SESSIONS` don't count.
  static bool secretName(String name) {
    for (final part in name.toUpperCase().split(RegExp('[^A-Z0-9]+'))) {
      if (_secretWords.contains(part)) return true;
      for (final end in _secretEnds) {
        if (part.endsWith(end)) return true;
      }
    }
    return false;
  }

  static const _secretWords = {
    'KEY', 'KEYS', 'TOKEN', 'TOKENS', 'SECRET', 'SECRETS', 'PASSWORD', 'PASSWD', 'PASS', 'PASSPHRASE', 'AUTH', //
    'CREDENTIAL', 'CREDENTIALS', 'COOKIE', 'DSN',
  };
  static const _secretEnds = ['APIKEY', 'TOKEN', 'SECRET', 'PASSWORD', 'PASSWD'];

  /// Key shapes: never sent out, and hidden in tool output.
  static final _credentials = <(String, RegExp)>[
    ('an API key', RegExp(r'\b(sk|rk|pk)-[A-Za-z0-9_\-]{20,}')),
    ('a GitHub token', RegExp(r'\b(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}')),
    ('a Hugging Face token', RegExp(r'\bhf_[A-Za-z0-9]{20,}')),
    ('an AWS key', RegExp(r'\b(AKIA|ASIA)[0-9A-Z]{16}\b')),
    ('a Slack token', RegExp(r'\bxox[abposr]-[A-Za-z0-9\-]{10,}')),
    ('a Google API key', RegExp(r'\bAIza[0-9A-Za-z_\-]{30,}')),
    (
      'an npm token',
      RegExp(
        r'\bnpm_[A-Za-z0-9]{36}\b|_authToken=[^\s"'
        "'"
        r']{8,}',
      ),
    ),
    // The whole block when it is all there, else its first line.
    (
      'a private key',
      RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----|-----BEGIN [A-Z ]*PRIVATE KEY',
      ),
    ),
    ('a JWT', RegExp(r'\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}')),
  ];

  /// Long blobs: they don't leave in a URL, but hashes, lockfiles and inline
  /// images in output are normal, so they aren't hidden.
  static final _blobs = <(String, RegExp)>[
    // Longer than any commit hash or content id a URL needs.
    ('a long hex blob', RegExp(r'[0-9a-fA-F]{64,}')),
    ('a long base64 blob', RegExp(r'[A-Za-z0-9+/_\-]{120,}={0,2}')),
  ];

  /// What [text] would leak, or null when it looks clean.
  String? leak(String text) {
    final decoded = _decoded(text);
    for (final v in _values) {
      if (text.contains(v) || decoded.contains(v)) return 'a secret from your environment or .env files';
    }
    for (final (what, re) in [..._credentials, ..._blobs]) {
      if (re.hasMatch(text) || re.hasMatch(decoded)) return what;
    }
    if (_queryBlob(text)) return 'an encoded blob in the query';
    return null;
  }

  /// Whether one query value of the URL in [text] is a long run of mixed
  /// base64 (letters of both cases and digits): data packed to leave, which
  /// the whole-text rule only catches when much longer.
  static bool _queryBlob(String text) {
    final q = text.indexOf('?');
    if (q < 0) return false;
    for (final pair in text.substring(q + 1).split(RegExp('[&#]'))) {
      final eq = pair.indexOf('=');
      if (eq > 0 && _pagingName.hasMatch(pair.substring(0, eq))) continue;
      final v = _decoded(pair.substring(eq + 1));
      if (v.length >= 48 &&
          RegExp(r'^[A-Za-z0-9+/_\-]+={0,2}$').hasMatch(v) &&
          RegExp('[a-z]').hasMatch(v) &&
          RegExp('[A-Z]').hasMatch(v) &&
          RegExp('[0-9]').hasMatch(v)) {
        return true;
      }
    }
    return false;
  }

  /// Query names whose values are long encoded tokens by design: paging cursors, OAuth state, request signatures.
  static final _pagingName = RegExp(
    r'^(cursor|after|before|next|prev|page_?token|next_?page_?token|continuation(_?token)?|state|signature|sig|'
    r'x-amz-signature|x-goog-signature)$',
    caseSensitive: false,
  );

  /// How a hidden value starts in [redact]'s output. The write tools refuse
  /// text with it, so the mark is never written over the real secret.
  static const hiddenMark = '[EVERYAI-HIDDEN:';

  /// [text] with secrets swapped for a fixed mark: known values, key shapes,
  /// and the values of secret-named `NAME=value` lines (`env`, `printenv`,
  /// `export -p`, `.env` files). The same text always gives the same result,
  /// so cached prompts stay stable.
  String redact(String text) {
    var out = text;
    // Longest first, so a value that contains another is hidden whole.
    for (final v in _values.toList()..sort((a, b) => b.length - a.length)) {
      if (out.contains(v)) out = out.replaceAll(v, '$hiddenMark secret]');
    }
    for (final (what, re) in _credentials) {
      out = out.replaceAll(re, '$hiddenMark $what]');
    }
    return out.replaceAllMapped(_assignment, (m) {
      if (!secretName(m[2]!) || _plainValue(m[4]!)) return m[0]!;
      return '${m[1]}${m[2]}=${m[3]}$hiddenMark secret]${m[3]}';
    });
  }

  /// `NAME=value` with an upper-case name at a line start or after a space,
  /// tab or colon (`declare -x`, `read`'s line numbers, grep's `file:12:`);
  /// a value of 8+ characters that isn't a `$` reference or another mark.
  static final _assignment = RegExp(r'''(^|[\s:])([A-Z][A-Z0-9_]*)=(["']?)(?![$\[])([^\s"']{8,})\3''', multiLine: true);

  /// The secret values of `NAME=value` lines in [text] (a `.env` file): those of secret-named variables, passwords
  /// in URLs, and values that look random. `NODE_ENV=development` or `APP_URL=http://localhost:3000` aren't secrets,
  /// and hiding them would garble ordinary output.
  static List<String> dotEnvLines(String text) {
    final out = <String>[];
    for (final line in text.split('\n')) {
      final eq = line.indexOf('=');
      if (line.trimLeft().startsWith('#') || eq < 1) continue;
      final name = line.substring(0, eq).trim().replaceFirst(RegExp(r'^export\s+'), '');
      var v = line.substring(eq + 1).trim();
      if (v.length >= 2 && (v[0] == '"' || v[0] == "'") && v.endsWith(v[0])) v = v.substring(1, v.length - 1);
      if (secretName(name) || _randomLooking(v)) {
        out.add(v);
      } else if (RegExp(r'^[a-z][a-z0-9+.-]*://[^/:@\s]*:([^@/\s]+)@').firstMatch(v) case final m?) {
        out.add(m[1]!); // postgres://user:password@host/db
      }
    }
    return out;
  }

  /// 16+ characters of letters and digits mixed, with no `/`, `:`, `.` or spaces: a key, not a word, path or URL.
  static bool _randomLooking(String v) =>
      v.length >= 16 &&
      RegExp(r'^[A-Za-z0-9+_=\-]+$').hasMatch(v) &&
      RegExp('[A-Za-z]').hasMatch(v) &&
      RegExp('[0-9]').hasMatch(v);

  static String _decoded(String text) {
    try {
      return Uri.decodeFull(text);
    } on Object {
      return text;
    }
  }

  /// The values set in `.env`, `.env.local` and the like in [dir].
  static List<String> dotEnvValues(String dir) {
    final out = <String>[];
    try {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!name.startsWith('.env') || name.endsWith('.example') || name.endsWith('.sample')) continue;
        out.addAll(dotEnvLines(f.readAsStringSync()));
      }
    } on Object {
      // An unreadable folder has nothing to add.
    }
    return out;
  }
}
