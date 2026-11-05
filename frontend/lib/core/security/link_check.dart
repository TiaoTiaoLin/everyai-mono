/// A look at a URL from model output before the user opens it or loads an
/// image from it. Model text can carry injected instructions, and a link or
/// image whose address holds parts of the chat (or a key) sends them to the
/// host the moment it opens. Clean links stay one tap; a flagged one shows
/// the real host and the reason first (see `chat/ui/link_gate.dart`).
library;

import '../../features/code/harness/everyai/scrub.dart';

/// A path segment, query value or fragment this long with no spaces looks
/// like encoded data rather than words (base64 of 36 bytes is 48 characters).
const longDataChars = 48;

/// A query plus fragment this long carries a lot whatever it looks like
/// (a prefilled mail body, a pasted chat).
const longQueryChars = 300;

final _dataChars = RegExp(r'^[A-Za-z0-9+/=_%.\-]+$');

/// Lowercase words joined by dashes, dots or underscores: a readable slug
/// (`how-to-set-up-riverpod-3-with-drift`), not data.
final _slug = RegExp(r'^[a-z0-9]{1,20}(?:[-_.][a-z0-9]{1,20})*$');

final _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

/// Why [uri] deserves a look before it opens, in plain words; null when it
/// looks like an ordinary link.
String? linkConcern(Uri uri) {
  final text = uri.toString();
  if (Scrubber().leak(text) case final what?) {
    return 'The address contains what looks like $what. Opening it would send that to ${linkDestination(uri)}.';
  }
  if (uri.userInfo.isNotEmpty) {
    return 'The address starts with "${uri.userInfo}@", which hides the real site: ${linkDestination(uri)}.';
  }
  final host = uri.host.toLowerCase();
  if (_ipv4.hasMatch(host) || host.contains(':') || RegExp(r'^\d+$').hasMatch(host)) {
    return 'The address is a bare network number, not a named site.';
  }
  if (host.split('.').any((label) => label.startsWith('xn--'))) {
    return 'The site name uses letters from another alphabet, which can imitate a familiar site.';
  }
  final pieces = [
    ...uri.path.split('/'),
    for (final pair in uri.query.split('&')) pair.substring(pair.indexOf('=') + 1),
    uri.fragment,
  ];
  if (pieces.any(_looksLikeData) || uri.query.length + uri.fragment.length > longQueryChars) {
    return 'The address carries a long block of data, which could hold parts of this chat.';
  }
  return null;
}

bool _looksLikeData(String piece) =>
    piece.length >= longDataChars && _dataChars.hasMatch(piece) && !_slug.hasMatch(piece);

/// Where [uri] really goes: its host, or the address of a `mailto:` link.
String linkDestination(Uri uri) => uri.scheme == 'mailto' ? uri.path : (uri.host.isEmpty ? '$uri' : uri.host);
