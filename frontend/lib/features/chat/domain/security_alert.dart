import 'dart:convert';

import 'message.dart';

/// The model's red security notice (backend `tools.zig` `security_alert`):
/// content tried to instruct it or make it do something harmful, a site or
/// account was not the right one, or something of the user's may have been
/// exposed. Shown as a card in the answer, never asks for anything.
const securityAlertTool = 'security_alert';

enum SecuritySeverity {
  info('Security note'),
  warning('Security warning'),
  critical('Security alert');

  const SecuritySeverity(this.label);
  final String label;
}

/// A decoded `security_alert` call. Bad or missing arguments fall back to
/// something still worth showing; every field is clipped for display.
class SecurityAlert {
  const SecurityAlert({
    required this.severity,
    required this.what,
    this.source,
    this.actionTaken,
    this.exposed = const [],
  });

  final SecuritySeverity severity;
  final String what;
  final String? source;
  final String? actionTaken;
  final List<String> exposed;

  static const _fallback = 'A security problem was found.';

  static SecurityAlert of(ToolCallPart part) => fromJson(part.argumentsJson);

  static SecurityAlert fromJson(String argumentsJson) {
    final args = _decoded(argumentsJson);
    if (args is! Map) return const SecurityAlert(severity: SecuritySeverity.warning, what: _fallback);
    String? text(Object? v, int max) {
      if (v is! String) return null;
      final t = v.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (t.isEmpty) return null;
      return t.length > max ? '${t.substring(0, max - 1)}…' : t;
    }

    final exposed = args['exposed'];
    return SecurityAlert(
      severity:
          SecuritySeverity.values.where((s) => s.name == args['severity']).firstOrNull ?? SecuritySeverity.warning,
      what: text(args['what'], 500) ?? _fallback,
      source: text(args['source'], 200),
      actionTaken: text(args['action_taken'], 500),
      exposed: [
        if (exposed is List)
          for (final e in exposed.take(8)) ?text(e, 200),
      ],
    );
  }

  static Object? _decoded(String json) {
    try {
      return jsonDecode(json);
    } on FormatException {
      return null;
    }
  }

  /// The line a later turn gets, so the model knows it already warned.
  String get note => '[Security notice shown to the user: $what]';
}
