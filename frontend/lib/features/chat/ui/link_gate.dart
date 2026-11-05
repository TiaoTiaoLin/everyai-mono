import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/security/link_check.dart';
import '../../../core/ui/adaptive.dart';

/// Opens [uri] outside the app (links in answers and artifacts, sources).
/// An ordinary link opens at once; one that [linkConcern] flags asks first,
/// showing the real destination and the whole address.
Future<void> openOutside(BuildContext context, Uri uri, {Future<bool> Function(Uri uri) launch = _launch}) async {
  if (await confirmRemote(context, uri)) await launch(uri);
}

/// Whether [uri] may be used (opened, or an image loaded from it): true at
/// once when it looks ordinary, else the user's answer.
Future<bool> confirmRemote(BuildContext context, Uri uri) async {
  final concern = linkConcern(uri);
  if (concern == null) return true;
  if (!context.mounted) return false;
  return showAdaptiveConfirm(
    context,
    title: 'Open ${linkDestination(uri)}?',
    message: concern,
    detail: uri.toString(),
    confirmLabel: 'Open',
  );
}

Future<bool> _launch(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
