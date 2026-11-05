// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// What research jobs may reach and read; no dart:io, so settings can use it on the web.

/// The sites research jobs may reach unless the user changes the list.
const defaultResearchSites = [
  'github.com',
  'api.github.com',
  'raw.githubusercontent.com',
  'gist.github.com',
  'gist.githubusercontent.com',
  'huggingface.co',
  'stackoverflow.com',
  '*.stackexchange.com',
  'developer.mozilla.org',
  'docs.python.org',
  'docs.rs',
  'crates.io',
  'pypi.org',
  'npmjs.com',
  'www.npmjs.com',
  'pkg.go.dev',
  'en.wikipedia.org',
  'arxiv.org',
];

/// Whether [host] is on [allow] (the backend's rule: an entry matches itself
/// and its www. form; `*.x` matches x and its subdomains).
bool hostAllowed(String host, List<String> allow) {
  final h = host.toLowerCase();
  final bare = h.startsWith('www.') ? h.substring(4) : h;
  for (final entry in allow) {
    final e = entry.toLowerCase();
    if (e.startsWith('*.')) {
      final base = e.substring(2);
      if (bare == base || bare.endsWith('.$base')) return true;
    } else if (bare == e || h == e) {
      return true;
    }
  }
  return false;
}

/// The names [secretPath] matches, as globs on a file or folder name, for
/// tools that search many files at once (grep): they skip these, since a
/// match would print the secret's lines. Negative globs only: a positive one
/// would let nothing else through.
const secretGlobs = [
  '.env*',
  '*.pem',
  '*.key',
  '*.p12',
  '*.pfx',
  'id_rsa',
  'id_ed25519',
  '.netrc',
  '.npmrc',
  '.pypirc',
  '.git-credentials',
  '.ssh',
  '.aws',
  '.gnupg',
  '.docker',
  '.kube',
];

/// Paths a research job may not read: secrets and credentials.
bool secretPath(String path) {
  final p = path.replaceAll('\\', '/');
  final name = p.split('/').last;
  return name.startsWith('.env') && !name.endsWith('.example') && !name.endsWith('.sample') ||
      RegExp(r'/\.(ssh|aws|gnupg|docker|kube|netrc|npmrc|pypirc|git-credentials)(/|$)').hasMatch(p) ||
      p.contains('/Library/Keychains/') ||
      RegExp(r'\.(pem|key|p12|pfx)$').hasMatch(name) ||
      name == 'id_rsa' ||
      name == 'id_ed25519';
}
