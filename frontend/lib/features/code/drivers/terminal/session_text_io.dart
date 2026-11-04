import 'dart:io';

import '../briefing/briefing_types.dart' show sessionFileName;

/// The session text written at session start, or null when it isn't there.
Future<String?> readSessionText(String briefingRoot) async {
  final file = File('$briefingRoot/$sessionFileName');
  return await file.exists() ? file.readAsString() : null;
}
