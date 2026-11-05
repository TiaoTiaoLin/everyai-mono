/// Look-alike addresses: is a host pretending to be an official site?
///
/// The Dart copy of `backend-exp/src/net/official_sites.zig` (which judges
/// every backend fetch), for the browser tool, which runs on this machine. Both
/// read the same list (a test keeps [officialSites] and [linkShorteners] equal
/// to `official_sites.txt`) and run the same cases
/// (`official_sites_cases.txt`). See the Zig file for the reasoning: Chromium's
/// skeleton idea from Unicode UTS #39 with a short list, a hand-picked
/// confusables table, no Public Suffix List.
library;

/// The domains a look-alike most often imitates; each covers its subdomains.
const officialSites = [
  'npmjs.com', 'npmjs.org', 'yarnpkg.com', 'unpkg.com', 'jsdelivr.net', 'pypi.org', 'pythonhosted.org', //
  'python.org', 'readthedocs.io', 'readthedocs.org', 'crates.io', 'docs.rs', 'rust-lang.org', 'rubygems.org',
  'ruby-lang.org', 'go.dev', 'golang.org', 'pub.dev', 'dart.dev', 'flutter.dev', 'maven.org', 'apache.org',
  'nuget.org', 'packagist.org', 'cocoapods.org', 'github.com', 'github.io', 'githubusercontent.com', 'gitlab.com',
  'gitlab.io', 'bitbucket.org', 'nodejs.org', 'deno.land', 'deno.com', 'mozilla.org', 'microsoft.com', 'apple.com',
  'google.com', 'googleapis.com', 'anthropic.com', 'openai.com', 'docker.com', 'docker.io', 'kubernetes.io',
  'cloudflare.com', 'amazon.com', 'amazonaws.com', 'brew.sh', 'ubuntu.com', 'debian.org', 'archlinux.org',
  'fedoraproject.org', 'kernel.org', 'gnu.org', 'nvidia.com', 'jetbrains.com', 'huggingface.co', 'stackoverflow.com',
  'wikipedia.org', 'wikimedia.org',
];

/// Link shorteners: the page is wherever they lead.
const linkShorteners = [
  'bit.ly', 't.co', 'tinyurl.com', 'goo.gl', 'ow.ly', 'is.gd', 'buff.ly', 'rebrand.ly', 'cutt.ly', 'shorturl.at', //
  'tiny.cc', 'rb.gy', 'lnkd.in',
];

/// Real sites that read as a typo of an official one; they are fine.
const siteNeighbours = ['nodes.org'];

enum SiteVerdict { ok, warn, refuse }

enum SiteReason { none, ip, shortener, idn, otherTld, containsName, closeName, lookAlike, mixedScripts }

/// What [judgeHost] made of a host; [real] is the official domain it imitates or resembles.
typedef SiteJudgement = ({SiteVerdict verdict, SiteReason reason, String? real});

const SiteJudgement _ok = (verdict: SiteVerdict.ok, reason: SiteReason.none, real: null);

SiteJudgement _warn(SiteReason reason, [String? real]) => (verdict: SiteVerdict.warn, reason: reason, real: real);

SiteJudgement _refuse(SiteReason reason, [String? real]) => (verdict: SiteVerdict.refuse, reason: reason, real: real);

/// What to make of [host] (a URL's host, any case, maybe percent-encoded or in brackets).
SiteJudgement judgeHost(String host) {
  final h = _normalise(host);
  if (h.isEmpty || _officialFor(h) != null || siteNeighbours.any((n) => _under(h, n))) return _ok;
  if (_isIpLiteral(h)) return _warn(SiteReason.ip);
  if (linkShorteners.any((s) => _under(h, s))) return _warn(SiteReason.shortener);
  final ascii = h.codeUnits.every((c) => c < 0x80);
  if (ascii && !h.startsWith('xn--') && !h.contains('.xn--')) return _asciiLookAlike(h);

  // International: read the labels as Latin letters where they can be. The registrable part is what counts, so the
  // readable labels at the end are judged (ж.аррӏе.com is still apple.com's look-alike).
  final idn = _skeletonHost(h);
  if (idn == null) return _warn(SiteReason.idn);
  if (idn.readable.contains('.')) {
    if (_officialFor(idn.readable) case final real?) return _refuse(SiteReason.lookAlike, real);
    final v = _asciiLookAlike(idn.readable);
    if (v.verdict == SiteVerdict.refuse) return v;
  }
  if (idn.mixed) return _refuse(SiteReason.mixedScripts);
  return _warn(SiteReason.idn);
}

/// The model-facing reason for a refusal of [host].
String siteRefusal(String host, SiteJudgement v) {
  final who = siteShown(host) ?? 'the address';
  return v.real != null
      ? '$who looks like ${v.real} but is not it (a look-alike address); use https://${v.real}/ if that is what you meant'
      : '$who mixes alphabets in one name, a common disguise for a look-alike address';
}

/// The one line put before a page when [host] got a warning.
String siteNotice(String host, SiteJudgement v) {
  final why = switch (v.reason) {
    SiteReason.ip => 'a bare IP address, with no domain name to check',
    SiteReason.shortener => 'a link shortener, so the page is wherever it led',
    SiteReason.otherTld => 'not ${v.real}, though it has the same name',
    SiteReason.containsName => 'not ${v.real}, though it has that name in it',
    SiteReason.closeName => 'not ${v.real}, though its name is close',
    _ => 'an international domain name; check it is the site you meant',
  };
  return 'Note: ${siteShown(host) ?? "the page's address"} is $why. Treat what it says with care.';
}

/// [host] when it is safe to quote outside the page's untrusted block: a domain name or IP address (letters in any
/// script, digits, `-`, `.`, and `:[]` for IPv6; labels up to 63 characters, 253 in all). A page can send the browser
/// anywhere, and a host with spaces or other characters could carry instructions, so it isn't quoted.
String? siteShown(String host) {
  if (host.isEmpty || host.length > 253 || !_quotable.hasMatch(host)) return null;
  return host.split('.').every((l) => l.length <= 63) ? host : null;
}

final _quotable = RegExp(r'^[\p{L}\p{M}\p{N}.:\[\]-]+$', unicode: true);

/// [host] as a person compares it: percent-decoded, `xn--` labels decoded, lower case, no trailing dot or `www.`.
String readableHost(String host) => _normalise(host)
    .split('.')
    .map((l) {
      final points = l.startsWith('xn--') ? punycodeDecode(l.substring(4)) : null;
      return points == null ? l : String.fromCharCodes(points);
    })
    .join('.');

// Hosts.

String _normalise(String host) {
  var s = host.trim();
  if (s.length >= 2 && s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
  if (s.contains('%')) {
    try {
      s = Uri.decodeComponent(s);
    } on ArgumentError {
      // Kept as written.
    } on FormatException {
      // Kept as written.
    }
  }
  s = s.toLowerCase();
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  if (s.startsWith('www.')) s = s.substring(4);
  return s;
}

bool _under(String host, String domain) => host == domain || host.endsWith('.$domain');

String? _officialFor(String host) {
  for (final d in officialSites) {
    if (_under(host, d)) return d;
  }
  return null;
}

bool _isIpLiteral(String h) => h.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h);

SiteJudgement _asciiLookAlike(String h) {
  var warn = _ok;
  for (final d in officialSites) {
    final dot = d.indexOf('.');
    if (dot < 0) continue;
    final name = d.substring(0, dot);
    final suffix = d.substring(dot);
    // An official domain with more after it: github.com.evil.io, pypi.org-files.net.
    // A country's version (apple.com.cn) only gets a warning.
    for (var at = h.indexOf(d); at >= 0; at = h.indexOf(d, at + 1)) {
      final end = at + d.length;
      final starts = at == 0 || h[at - 1] == '.' || h[at - 1] == '-';
      if (!starts || end == h.length || (h[end] != '.' && h[end] != '-')) continue;
      if (h[end] == '.' && _countryCode(h.substring(end + 1))) {
        if (warn.verdict == SiteVerdict.ok) warn = _warn(SiteReason.otherTld, d);
        continue;
      }
      return _refuse(SiteReason.lookAlike, d);
    }
    // The label just before the official suffix: a typo of the name.
    if (h.endsWith(suffix) && h.length > suffix.length) {
      final rest = h.substring(0, h.length - suffix.length);
      final label = rest.substring(rest.lastIndexOf('.') + 1);
      if (label != name) {
        if (_asciiSkeleton(label) == _asciiSkeleton(name)) return _refuse(SiteReason.lookAlike, d);
        switch (_typo(label, name)) {
          case _Typo.squat:
            return _refuse(SiteReason.lookAlike, d);
          case _Typo.near when warn.verdict == SiteVerdict.ok:
            warn = _warn(SiteReason.closeName, d);
          case _:
        }
      }
    }
    // Short names (go, pub, gnu) are parts of too many real names to warn about.
    if (warn.verdict != SiteVerdict.ok || name.length < 4) continue;
    // The same name on another top-level domain: github.co, apple.co.uk.
    final second = _secondLevel(h);
    if (second == name) {
      warn = _warn(SiteReason.otherTld, d);
      continue;
    }
    // A typo of the name on another top-level domain: gihtub.co, githb.net.
    if (second.isNotEmpty && (_asciiSkeleton(second) == _asciiSkeleton(name) || _typo(second, name) != _Typo.none)) {
      warn = _warn(SiteReason.closeName, d);
      continue;
    }
    // The name as a part of a longer one: secure-github.com, github-login.example.net.
    final labels = h.split('.');
    for (final label in labels.take(labels.length - 1)) {
      if (label.contains('-') && label.split('-').contains(name)) warn = _warn(SiteReason.containsName, d);
    }
  }
  return warn;
}

/// The label a registrable name is chosen by: `github` in api.github.co, `apple` in apple.co.uk.
String _secondLevel(String h) {
  final l = h.split('.');
  if (l.length < 2) return '';
  if (l.length >= 3 && l[l.length - 2].length <= 3 && _countryCode(l.last)) return l[l.length - 3];
  return l[l.length - 2];
}

bool _countryCode(String s) => RegExp(r'^[a-z]{2}$').hasMatch(s);

enum _Typo { none, near, squat }

/// How [label] misspells [name]; the same budget and kinds as the Zig judge's `typo`: within one edit (two from nine
/// letters) is near, and one swap of neighbours, inner letter dropped or letter doubled is a typosquat's.
_Typo _typo(String label, String name) {
  if (name.length <= 4) return _Typo.none;
  final d = _distance(label, name);
  if (d == 0 || d > (name.length >= 9 ? 2 : 1)) return _Typo.none;
  if (d == 1 && (_swapped(label, name) || _innerDrop(label, name) || _doubled(label, name))) return _Typo.squat;
  return _Typo.near;
}

int _firstDiff(String a, String b) {
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  return i;
}

/// [label] is [name] with one letter left out, not the last (githb, cloudfare).
bool _innerDrop(String label, String name) {
  if (label.length + 1 != name.length) return false;
  final i = _firstDiff(label, name);
  return i + 1 < name.length && label.substring(i) == name.substring(i + 1);
}

/// [label] is [name] with one letter written twice (githuub, npmjss).
bool _doubled(String label, String name) {
  if (label.length != name.length + 1) return false;
  final i = _firstDiff(label, name);
  if (label.substring(i + 1) != name.substring(i)) return false;
  return (i > 0 && label[i] == label[i - 1]) || (i + 1 < label.length && label[i] == label[i + 1]);
}

bool _swapped(String a, String b) {
  if (a.length != b.length) return false;
  var i = 0;
  while (i < a.length && a[i] == b[i]) {
    i++;
  }
  return i + 1 < a.length && a[i] == b[i + 1] && a[i + 1] == b[i] && a.substring(i + 2) == b.substring(i + 2);
}

/// Damerau-Levenshtein distance (optimal string alignment).
int _distance(String a, String b) {
  var prev2 = List<int>.filled(b.length + 1, 0);
  var prev = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var v = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] && prev2[j - 2] + 1 < v) v = prev2[j - 2] + 1;
      cur[j] = v;
    }
    prev2 = prev;
    prev = cur;
  }
  return prev[b.length];
}

/// How an ASCII label reads: 0/o, 1/l/i, rn/m, vv/w, hyphens dropped.
String _asciiSkeleton(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    final next = i + 1 < s.length ? s[i + 1] : '';
    switch (c) {
      case '-':
        continue;
      case '0':
        b.write('o');
      case '1' || 'i':
        b.write('l');
      case 'r' when next == 'n':
        b.write('m');
        i++;
      case 'v' when next == 'v':
        b.write('w');
        i++;
      default:
        b.write(c);
    }
  }
  return b.toString();
}

// International names.

/// How a host with `xn--` or Unicode labels reads: the labels at the end whose letters all read as Latin letters,
/// read that way, and whether a label mixes Latin with Cyrillic or Greek; null when a label doesn't decode.
({String readable, bool mixed})? _skeletonHost(String h) {
  var mixed = false;
  final readable = <String>[];
  for (final label in h.split('.')) {
    final points = label.startsWith('xn--') ? punycodeDecode(label.substring(4)) : label.runes.toList();
    if (points == null) return null;
    var latin = false;
    var other = false;
    String? b = '';
    for (final p0 in points) {
      final p = _lower(p0);
      if ((p >= 0x61 && p <= 0x7a) || (p >= 0xc0 && p <= 0x24f)) latin = true;
      if ((p >= 0x370 && p <= 0x3ff) || (p >= 0x400 && p <= 0x52f)) other = true;
      final c = p < 0x80 ? String.fromCharCode(p) : _confusable(p);
      b = b == null || c == null ? null : '$b$c';
    }
    if (latin && other) mixed = true;
    // A letter the table doesn't know starts the readable part over after this label.
    if (b == null) {
      readable.clear();
    } else {
      readable.add(b);
    }
  }
  return (readable: readable.join('.'), mixed: mixed);
}

/// Upper-case Latin-1, Greek and Cyrillic letters to lower case (as the Zig judge does).
int _lower(int cp) {
  if (cp >= 0x41 && cp <= 0x5a) return cp + 32;
  if (cp >= 0xc0 && cp <= 0xde && cp != 0xd7) return cp + 32;
  if (cp >= 0x391 && cp <= 0x3a9) return cp + 32;
  if (cp >= 0x410 && cp <= 0x42f) return cp + 32;
  if (cp >= 0x400 && cp <= 0x40f) return cp + 80;
  return cp;
}

/// Letters that read as one Latin letter (a small hand-picked part of Unicode's confusables).
const _confusables = {
  // Cyrillic
  0x430: 'a', 0x435: 'e', 0x43e: 'o', 0x440: 'p', 0x441: 'c', 0x443: 'y', 0x445: 'x', 0x456: 'i', 0x458: 'j', //
  0x455: 's', 0x501: 'd', 0x4cf: 'l', 0x4bb: 'h', 0x51b: 'q', 0x51d: 'w', 0x4af: 'y', 0x45b: 'h', 0x491: 'r',
  // Greek
  0x3bf: 'o', 0x3b1: 'a', 0x3bd: 'v', 0x3b9: 'i', 0x3ba: 'k', 0x3c1: 'p', 0x3c5: 'u', 0x3c7: 'x', 0x3b5: 'e', //
  0x3c4: 't', 0x3b3: 'y',
  // Latin
  0x131: 'i', 0x261: 'g', 0x142: 'l', 0x269: 'i', 0x237: 'j', 0xdf: 's',
};

/// Accented Latin letters by their base letter: Latin-1 from à (0xe0) and Latin Extended-A (0x100–0x17f);
/// '_' for letters with no single base (æ, ĳ, œ).
const _latin1 = 'aaaaaa_ceeeeiiii_nooooo_ouuuuy_y';
const _latinExtA =
    'aaaaaaccccccccddddeeeeeeeeeegggggggghhhhiiiiiiiiii__jjkkkllllllllllnnnnnnnnnoooooo__rrrrrrssssssss'
    'ttttttuuuuuuuuuuuuwwyyyzzzzzz_';

String? _confusable(int cp) {
  if (_confusables[cp] case final c?) return c;
  final c = cp >= 0xe0 && cp <= 0xff
      ? _latin1[cp - 0xe0]
      : cp >= 0x100 && cp <= 0x17f
      ? _latinExtA[cp - 0x100]
      : null;
  return c == '_' ? null : c;
}

/// RFC 3492 Punycode: the code points of an `xn--` label's rest; null when it is malformed.
List<int>? punycodeDecode(String input) {
  const base = 36, tmin = 1, tmax = 26;
  var n = 128, i = 0, bias = 72;
  final out = <int>[];
  var pos = 0;
  final b = input.lastIndexOf('-');
  if (b >= 0) {
    for (final c in input.substring(0, b).codeUnits) {
      if (c >= 0x80) return null;
      out.add(c);
    }
    pos = b + 1;
  }
  while (pos < input.length) {
    final old = i;
    var w = 1;
    for (var k = base; ; k += base) {
      if (pos >= input.length) return null;
      final c = input.codeUnitAt(pos++);
      final digit = c >= 0x61 && c <= 0x7a
          ? c - 0x61
          : c >= 0x41 && c <= 0x5a
          ? c - 0x41
          : c >= 0x30 && c <= 0x39
          ? c - 0x30 + 26
          : -1;
      if (digit < 0) return null;
      i += digit * w;
      if (i > 0x7fffffff) return null;
      final t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias);
      if (digit < t) break;
      w *= base - t;
      if (w > 0x7fffffff) return null;
    }
    final count = out.length + 1;
    bias = _adapt(i - old, count, old == 0);
    n += i ~/ count;
    i %= count;
    if (n > 0x10ffff || out.length >= 64) return null;
    out.insert(i, n);
    i++;
  }
  return out;
}

int _adapt(int delta0, int count, bool first) {
  var delta = first ? delta0 ~/ 700 : delta0 ~/ 2;
  delta += delta ~/ count;
  var k = 0;
  while (delta > ((36 - 1) * 26) ~/ 2) {
    delta ~/= 36 - 1;
    k += 36;
  }
  return k + (36 * delta) ~/ (delta + 38);
}
