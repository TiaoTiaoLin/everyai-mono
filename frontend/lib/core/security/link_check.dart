/// A look at a URL from model output before the user opens it or loads an
/// image from it. Model text can carry injected instructions, and a link or
/// image whose address holds parts of the chat (or a key) sends them to the
/// host the moment it opens. Clean links stay one tap; a flagged one shows
/// the real host and the reason first (see `chat/ui/link_gate.dart`).
///
/// This catches data that is long or shaped like a key. A short leak (a name,
/// a PIN in a few characters) looks like any other link and can't be told
/// apart here.
library;

import '../../features/code/harness/everyai/scrub.dart';

/// A path segment or fragment this long with no spaces looks like encoded
/// data rather than words (base64 of 36 bytes is 48 characters).
const longDataChars = 48;

/// A host label this long (other than the site's own name) looks like data:
/// subdomains are short words.
const longLabelChars = 32;

/// A query value this long once decoded carries a sentence or more (a
/// prefilled mail body, a pasted chat), whatever it looks like.
const longValueChars = 80;

/// Path, query and fragment together this long, once decoded, carry a lot even
/// when cut into short pieces.
const longAddressChars = 300;

final _dataChars = RegExp(r"^[A-Za-z0-9+/=_%.,:;!*'()~@$\-]+$");

/// Lowercase words joined by dashes, dots or underscores: a readable slug
/// (`how-to-set-up-riverpod-3-with-drift`), not data.
final _slug = RegExp(r'^[a-z0-9]{1,20}(?:[-_.][a-z0-9]{1,20})*$');

/// A host label a browser reads as part of an IPv4 address: decimal, octal or
/// `0x` hex (`127.1` and `0x7f.1` are both 127.0.0.1).
final _numericLabel = RegExp(r'^(?:\d+|0x[0-9a-f]*)$');

final _loopback = RegExp(r'^127(?:\.\d{1,3}){3}$');

/// Why [uri] deserves a look before it opens, in plain words; null when it
/// looks like an ordinary link.
String? linkConcern(Uri uri) {
  final host = uri.host.toLowerCase();
  final labels = host.split('.');
  final query = [
    for (final pair in uri.query.split('&'))
      if (pair.indexOf('=') case final i) ...[if (i > 0) pair.substring(0, i), pair.substring(i + 1)],
  ];
  final pieces = [...labels, ...uri.path.split('/'), ...query, uri.fragment];
  // Per piece, so a readable slug isn't taken for a base64 run.
  for (final piece in pieces) {
    if (_slug.hasMatch(piece)) continue;
    if (Scrubber().leak(piece) case final what?) {
      return 'The address contains what looks like $what. Opening it would send that to ${linkDestination(uri)}.';
    }
  }
  if (uri.userInfo.isNotEmpty) {
    return 'The address starts with "${uri.userInfo}@", which hides the real site: ${linkDestination(uri)}.';
  }
  final numeric = host.contains(':') || labels.every(_numericLabel.hasMatch);
  if (numeric && !_loopback.hasMatch(host) && host != '::1' && host != '[::1]') {
    return 'The address is a bare network number, not a named site.';
  }
  if (labels.any((label) => label.startsWith('xn--')) || _decode(host).codeUnits.any((c) => c > 0x7f)) {
    return 'The site name uses letters from another alphabet, which can imitate a familiar site.';
  }
  final subdomains = labels.length > 2 ? labels.sublist(0, labels.length - 2) : const <String>[];
  if (subdomains.any((l) => l.length >= longLabelChars && !_slug.hasMatch(l)) ||
      [...uri.path.split('/'), ...query, uri.fragment].any(_looksLikeData) ||
      query.any((v) => _decode(v).length >= longValueChars) ||
      _decode('${uri.path}?${uri.query}#${uri.fragment}').length > longAddressChars) {
    return 'The address carries a long block of data, which could hold parts of this chat.';
  }
  return null;
}

bool _looksLikeData(String piece) =>
    piece.length >= longDataChars && _dataChars.hasMatch(piece) && !_slug.hasMatch(piece);

String _decode(String s) {
  try {
    return Uri.decodeQueryComponent(s);
  } on Object {
    return s;
  }
}

/// Where [uri] really goes: its host, or the address of a `mailto:` link.
String linkDestination(Uri uri) => uri.scheme == 'mailto' ? uri.path : (uri.host.isEmpty ? '$uri' : uri.host);
