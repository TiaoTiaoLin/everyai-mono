import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/decide_client.dart';
import 'gateway_key.dart';

/// Which command the approval card asks about, and where it runs.
typedef RiskKey = ({String command, String workingDir});

/// The decide questions asked about a command the user must approve.
const riskQuestions = [
  DecideQuestion.yesNo('read_only', 'Does the command only read (no files, processes or state changed)?'),
  DecideQuestion.yesNo('destructive', 'Could it delete or overwrite files or data, or be hard to undo?'),
  DecideQuestion.yesNo('network', 'Does it use the network (downloads, uploads, API calls, installs)?'),
  DecideQuestion.yesNo('outside_project', 'Does it read or write anything outside the working directory?'),
];

const _instructions =
    'A coding agent wants to run this shell command on the user\'s computer. '
    'Answer for what the command does as written; answer unsure when it depends on files you cannot see.';

/// A one-line, informational read of a command: "Looks read-only", "May
/// delete files · uses the network", "Unsure". Null when the call failed (no
/// label then). It never decides anything: approval stays with the user.
String? riskLabel(DecideResult r) {
  if (r.failed) return null;
  if (r.allUnsure) return 'Unsure';
  final readOnly = r['read_only'].asBool;
  final destructive = r['destructive'].asBool == true;
  final extras = [
    if (r['network'].asBool == true) 'uses the network',
    if (r['outside_project'].asBool == true) 'reaches outside the project',
  ];
  final String head;
  if (destructive) {
    head = 'May delete files';
  } else if (readOnly == true) {
    head = 'Looks read-only';
  } else if (extras.isNotEmpty) {
    final first = extras.removeAt(0);
    head = '${first[0].toUpperCase()}${first.substring(1)}';
  } else {
    head = readOnly == false ? 'Changes files in the project' : 'Unsure';
  }
  return [head, ...extras].join(' · ');
}

/// The risk label for a command waiting for approval, from one decide call
/// (job "risk") on the user's gateway key, or the JWT when there is none.
/// Kept for the app's life once it arrives, so a card shown again doesn't
/// ask twice; a failed call is retried the next time a card asks.
final approvalRiskProvider = FutureProvider.autoDispose.family<String?, RiskKey>((ref, key) async {
  final keep = ref.keepAlive();
  String? apiKey;
  try {
    apiKey = await ref.read(gatewayKeysProvider).key();
  } on Object {
    apiKey = null;
  }
  final result = await ref
      .read(decideClientProvider)
      .decide(
        job: 'risk',
        text: 'Command:\n${key.command}\n\nWorking directory: ${key.workingDir}',
        instructions: _instructions,
        questions: riskQuestions,
        apiKey: apiKey,
      );
  final label = riskLabel(result);
  if (label == null) keep.close();
  return label;
});
