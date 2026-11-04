// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/spill.dart';
import '../spill/spill.dart';
import 'host.dart' show HostResult;

// Output spill for the host's own tools (check, bug_check, run_script): a
// long result goes to `.everyai/spill/` and the agent reads a preview that
// names the file. An outside agent's own tools can't be spilled this way:
// its model already read their whole output.

/// [r], or its preview with the whole text saved as [name] under
/// [workingDir] when it is over the spill limits.
HostResult hostFit(String workingDir, String name, HostResult r) {
  final spill = spillText(r.text);
  if (spill == null) return r;
  final path = saveSpill(workingDir, Spill.fileName(name), spill.text);
  return path == null ? r : (text: spillPreview(spill, path), isError: r.isError);
}
