// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'workflow_engine.dart';

/// The status as the card and the summary say it.
String workflowStatusText(WorkflowStatus s) => switch (s) {
  WorkflowStatus.running => 'Running',
  WorkflowStatus.done => 'Done',
  WorkflowStatus.failed => 'Failed',
  WorkflowStatus.capped => 'Hit its limit',
  WorkflowStatus.stopped => 'Stopped',
};

/// `4m 12s`, `45s`, `1h 2m`.
String workflowDuration(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
  return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
}

const _lineChars = 240;

/// The most findings listed one by one.
const _listed = 8;

/// A verdict-first reading of [run], for the card and the lead: one status line, then what the result says,
/// whatever the script returned (a shape it doesn't know gets the status line only). The full JSON is shown apart,
/// so nothing here repeats a field.
String workflowSummary(WorkflowRun run) {
  final cost = run.spentMicros > 0 ? ' · \$${(run.spentMicros / 1e6).toStringAsFixed(2)}' : '';
  final agents = ' · ${run.started} ${run.started == 1 ? 'agent' : 'agents'}';
  final took = run.took == null ? '' : ' · ${workflowDuration(run.took!)}';
  final lines = ['Workflow: ${run.name} · ${workflowStatusText(run.status)}$cost$agents$took'];
  if (run.error case final e? when e.trim().isNotEmpty) lines.add('Error: ${_cut(e)}');
  final r = run.result;
  if (r is Map) {
    if (r['items'] is List) {
      _ultra(r, lines);
    } else if (r.containsKey('fix_summary')) {
      _bugfix(r, lines);
    } else if (r['findings'] is List) {
      _security(r, lines);
    }
  }
  return lines.join('\n');
}

void _bugfix(Map<Object?, Object?> r, List<String> out) {
  out.add(
    r['verified'] == true
        ? 'Outcome: fixed and proved'
        : r['verified'] == false
        ? 'Outcome: the fix is not proved'
        : 'Outcome: fix written',
  );
  _line(out, 'Cause', r['cause']);
  _line(out, 'Fix', r['fix_summary']);
  final proof = [_str(r['proof']), _str(r['repro_command'])].where((s) => s.isNotEmpty).join(' · ');
  if (proof.isNotEmpty) out.add('Proof: ${_cut(proof)}');
  _files(out, r['files']);
  _commits(out, r['commits']);
  if (r['review'] case final Map<Object?, Object?> review) {
    final findings = review['findings'];
    final counts = findings is List ? _counts(findings) : '';
    final text = [_str(review['verdict']), counts].where((s) => s.isNotEmpty).join(' · ');
    if (text.isNotEmpty) out.add('Review: $text');
  }
}

void _ultra(Map<Object?, Object?> r, List<String> out) {
  for (final it in (r['items'] as List<Object?>).whereType<Map<Object?, Object?>>()) {
    final counts = it['findings'] is List ? _counts(it['findings'] as List<Object?>) : '';
    final commits = it['commits'] is List ? (it['commits'] as List<Object?>).length : 0;
    final bits = [
      _str(it['status']),
      if (commits > 0) '$commits ${commits == 1 ? 'commit' : 'commits'}',
      counts,
      _str(it['error']),
    ].where((s) => s.isNotEmpty);
    out.add('- ${_str(it['id'])}: ${_cut(bits.join(' · '))}');
  }
  final integration = _str(r['integration']);
  if (integration.isNotEmpty) out.add('Integration: ${_cut(integration.split('\n').first)}');
  _line(out, 'Integration failed', r['integration_error']);
}

void _security(Map<Object?, Object?> r, List<String> out) {
  final findings = (r['findings'] as List<Object?>).whereType<Map<Object?, Object?>>().toList();
  if (findings.isEmpty) {
    out.add('Findings: none');
  } else {
    out.add('Findings: ${findings.length} (${_counts(findings, merge: false)})');
    for (final f in findings.take(_listed)) {
      final line = [_str(f['severity']), _str(f['file']), _str(f['summary'])].where((s) => s.isNotEmpty).join(' · ');
      out.add('- ${_cut(line)}');
    }
    if (findings.length > _listed) out.add('- and ${findings.length - _listed} more (see Details)');
    final merged = _counts(findings, severities: false);
    if (merged.isNotEmpty) out.add('Review: $merged');
  }
  if (r['verified'] is bool) {
    out.add(r['verified'] == true ? 'Verified: yes' : "Verified: no (the lenses' findings as they came)");
  }
}

const _rank = {'blocker': 5, 'critical': 5, 'major': 4, 'high': 4, 'minor': 3, 'medium': 3, 'low': 2, 'nit': 1};

/// `1 blocker, 2 minor, merged from 2 lenses`: severities from the highest down, then the merge note when a
/// finding names more than one lens.
String _counts(List<Object?> findings, {bool severities = true, bool merge = true}) {
  final bySeverity = <String, int>{};
  var lenses = 1;
  for (final f in findings.whereType<Map<Object?, Object?>>()) {
    final sev = _str(f['severity']).toLowerCase();
    if (sev.isNotEmpty) bySeverity[sev] = (bySeverity[sev] ?? 0) + 1;
    if (f['lenses'] case final List<Object?> l when l.length > lenses) lenses = l.length;
  }
  final order = bySeverity.keys.toList()..sort((a, b) => (_rank[b] ?? 0).compareTo(_rank[a] ?? 0));
  return [
    if (severities)
      for (final s in order) '${bySeverity[s]} $s',
    if (merge && lenses > 1) 'merged from $lenses lenses',
  ].join(', ');
}

void _files(List<String> out, Object? files) {
  if (files is! List || files.isEmpty) return;
  final names = files.map((f) => '$f').toList();
  out.add('Files: ${_cut(names.take(6).join(', '))}${names.length > 6 ? ' and ${names.length - 6} more' : ''}');
}

void _commits(List<String> out, Object? commits) {
  if (commits is! List || commits.isEmpty) return;
  out.add("Commits: ${commits.length}, in the workers' own branches; the files themselves are in your folder");
}

void _line(List<String> out, String label, Object? v) {
  final s = _str(v);
  if (s.isNotEmpty) out.add('$label: ${_cut(s)}');
}

String _str(Object? v) => v is String ? v.trim() : '';

String _cut(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= _lineChars ? one : '${one.substring(0, _lineChars - 1)}…';
}
