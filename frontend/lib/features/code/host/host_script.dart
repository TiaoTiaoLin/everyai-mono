// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'host.dart' show HostResult;
import 'host_script_stub.dart' if (dart.library.io) 'host_script_io.dart' as impl;

// run_script for an outside agent: the EveryAI harness's sandboxed Deno
// programs with only the free functions (readFile, grep, glob). decide,
// rank, llmQuery and the web would ask EveryAI's backend, and EveryAI
// spends nothing in a session it doesn't lead.

const runScriptTool = 'run_script';

const hostRunScriptSpec = <String, Object?>{
  'name': runScriptTool,
  'description':
      'Run a TypeScript program in a sandbox, for work that would otherwise take many tool calls or pull large '
      'outputs into your context: loop over files, filter grep results, scan a big log or a spilled output, and '
      'print only what you need. The program cannot touch files, the network or processes itself. It gets these '
      'async functions (await them):\n'
      '- readFile(path) → string: a file inside the project\n'
      '- grep(pattern, {path?, glob?, mode?: "files"|"content"|"count", caseInsensitive?, context?}) → string\n'
      '- glob(pattern, {path?}) → string[]\n'
      'Only what the program prints (console.log) comes back to you; long output is saved to a file and you get a '
      'preview. It is read-only. Prefer one script to many separate read or grep calls when you would read more '
      'than about five files or results just to filter them.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'code': {'type': 'string', 'description': 'The TypeScript program (top-level await works)'},
      'description': {'type': 'string', 'description': 'What it does, in a few words, for the user'},
      'timeout_seconds': {'type': 'number', 'description': 'Default 120, at most 600'},
    },
    'required': ['code'],
    'additionalProperties': false,
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};

/// Whether the host can offer run_script (Deno was found).
bool get hostScriptsAvailable => impl.hostScriptsAvailable;

/// Runs a run_script call in [root], with Deno's files under [stateDir].
Future<HostResult> hostRunScript(String root, String stateDir, Map<String, Object?> args, {Future<void>? cancel}) =>
    impl.hostRunScript(root, stateDir, args, cancel: cancel);
