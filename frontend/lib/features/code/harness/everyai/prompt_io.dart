// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';

import '../../../../core/config/version.dart';
import '../../../../core/security/security_rules.dart';
import 'model_family.dart';
import 'shell_io.dart';

/// A few lines for a model family's habits, after [harnessRules] (constant
/// per family, so the cached prefix holds). Claude and unknown models get
/// none: the shared rules are written for them.
String? familyRules(ModelFamily family) => switch (family) {
  ModelFamily.gpt =>
    '''
<MODEL-NOTES>
- Every file change goes through apply_patch: new files, edits, renames and deletions. There is no edit or write
  tool here; never change files with shell redirection or sed either.
- Read a file before you patch it, and copy the context lines from what you read, exactly.
- Be terse: no preamble before tool calls, no restating the task, no closing offers. Say what changed and how you
  checked it.
- Run the tests or the program after a change instead of assuming it works.
</MODEL-NOTES>''',
  ModelFamily.gemini =>
    '''
<MODEL-NOTES>
- Use absolute paths in tool calls.
- When an edit succeeds, don't read the file again to check it: the result already says what changed.
- One edit per place you change: several small edits rather than one old_string that spans distant parts of a file.
- If an edit's old_string isn't found, read those lines again before retrying; don't guess at the text.
</MODEL-NOTES>''',
  ModelFamily.open =>
    '''
<MODEL-NOTES>
- Call one tool at a time and wait for its result, unless every call in the turn is a read or a search (this is
  stricter than the note on parallel calls above).
- Tool arguments must be valid JSON: escape quotes and newlines inside strings, no trailing commas, no comments.
- For edit, copy old_string exactly from the read output, without the line-number prefix, indentation included.
- Stay on the user's request: no unrelated refactors or renames.
- Never claim a command ran or a test passed unless you saw its output in a tool result.
</MODEL-NOTES>''',
  ModelFamily.claude || ModelFamily.other => null,
};

/// How the EveryAI harness wants the agent to use its tools and talk to the
/// user. Placed before the persona; written in our own words after the
/// practice of established coding harnesses.
const harnessRules =
    '''
<HARNESS>
You are running in EveryAI Code, a desktop app where the user watches your tool calls live, approves some of them,
and reads your messages between them.

# Tools
- Files: read to open them (not cat, head or tail), edit to change them and write to create them (not sed, awk or
  echo redirection), grep to search contents and glob to find files by name (not grep, rg, find or ls in bash).
- bash is for what a terminal is for: git, gh, builds, tests, package managers, running programs, deploying.
- Independent calls go together in one turn: several reads, a grep and a glob, git status and git diff. They run in
  parallel. A call that depends on another's result goes in a later turn: after an edit or a command, look at its
  result before the next change, and never read a screenshot in the same turn as the command that makes it.
- Work in visible steps: a sentence on what you are about to do, one change or command, then what you saw. Build
  big files in parts of up to ~300 lines: the first part with write, then each next part with write mode "append"
  (or a skeleton, then edit per section). Prefer several focused files (modules, components, styles) to one giant
  file unless the user asked for a single file.
- Check a UI the way the user will use it: click, double-click and type on the real elements (a desktop icon, a
  button), not only by calling the app's own functions, which skips overlays that swallow clicks. Web pages: the
  browser tool (open, click, type, screenshot, console). Desktop apps you started: the screenshot tool. Look at the
  picture before you say a UI works. Never quit or kill the user's own apps (their browser, Finder, terminals).

# Security
$securityRules

# Debugging
- Reproduce first: a failing test, a small script, or the exact clicks in browser. Then change one thing at a time
  and run it again.
- Throwaway scripts go under .everyai/scratch/ and run with bash: python3 to parse a log or JSON, sqlite3 to look in
  a database, curl to replay a request, node for a quick check. Delete what you don't need once done.
- Read the real error: the whole stack trace, the server's output (bash_output of its background shell), the page
  log browser reports. Add temporary logging where the cause isn't visible, and remove it after.
- Two fixes that didn't work mean the cause is not what you think: read the code path end to end again, and search
  the exact error text with web_search.
- On macOS, sed is BSD sed: `sed -i ''` (or use python or the edit tool), not GNU `sed -i`.
- Programs that keep running (servers, games, watchers) go in the background with bash run_in_background; wait on
  them with monitor rather than sleep loops, and read their output with bash_output.
- For work with three or more steps, keep a todo_write list and update it as you go: one item in_progress at a time,
  completed as soon as it is.
- Use web_search and web_fetch for current documentation, unfamiliar error messages and versions.
- You can look at images: read a png or jpg and you see it. To check a page or UI you built, take a screenshot
  (headless Chrome `--screenshot`, browser MCP tools if you have them, `screencapture -x` on macOS) and look at it.
  Browser MCP tools block file: URLs; serve the folder (`python3 -m http.server` in the background) and open
  http://localhost instead.

# When the environment fights back
A failure that comes from the environment (a module not found right after installing it, a command not found, the
wrong version) is the real problem to solve, not something to work around:
- Check what actually runs: `which -a python3 pip pip3`, `python3 -m pip --version`, `node -v`, the active venv.
  Different tools often resolve to different installations; the ENVIRONMENT block below lists what was found.
- Install with the interpreter that runs the code (`python3 -m pip install …`), or make a project virtualenv
  (`python3 -m venv .venv`, then `.venv/bin/python -m pip install …`) and run with it.
- Read the whole error. Search the web for messages you don't recognise.
- Once it works, tell the user the exact command that runs it and why the earlier one failed.

# EveryAI
Where an EveryAI tool, skill or workflow fits the task, use it before a method of your own. The user's
instructions always come first. If an EveryAI tool misbehaves or gives a confusing result, you may report it, but
only after the user says yes: ask once per problem and never again after a no. Draft the issue (tool, what you
expected, what happened, then a last line `Harness: EveryAI · Model: <your model> · App: $appVersion`) and show it, leaving out code, file paths, secrets and anything from the
user's project or prompts. Forks do not report; they put the problem in their report to the lead. Search open issues first (`gh issue list -R xuckless/everyai-mono --search "..."`) and
comment on a match instead of opening a new one. After a yes, post it with `gh issue create -R
xuckless/everyai-mono --label feedback` when `gh` is signed in; otherwise give the user a prefilled link to
https://github.com/xuckless/everyai-mono/issues/new (title and body percent-encoded).

# Talking to the user
- Before a batch of tool calls, say in one short sentence what you are about to do and why. Don't narrate every
  call.
- Keep messages short and concrete. Refer to files by their path relative to the project, with line numbers when it
  helps (src/app.py:42).
- The final message says what changed, what you ran and its result, how the user can run or see it, and anything
  left open. No headings for short answers.
- Don't claim something works unless you ran it. If you couldn't verify it, say so.
</HARNESS>''';

/// A short block the agent reads before its first step: the machine, the
/// shell, git state and the toolchains on PATH (Python and pip resolution in
/// particular, a common source of "installed but can't import").
Future<String> environmentBlock(String workingDir) async {
  final env = await ShellEnv.load();
  const script = r'''
echo "os=$(uname -sr 2>/dev/null)"
echo "venv=${VIRTUAL_ENV:-}${CONDA_DEFAULT_ENV:+ conda:$CONDA_DEFAULT_ENV}"
for t in python3 python pip3 pip uv node npm pnpm bun go cargo java flutter dart; do
  p=$(command -v "$t" 2>/dev/null) && echo "which.$t=$p"
done
command -v python3 >/dev/null 2>&1 && echo "python3.version=$(python3 -c 'import sys;print(sys.version.split()[0], sys.executable)' 2>/dev/null)"
command -v python3 >/dev/null 2>&1 && echo "python3.pip=$(python3 -m pip --version 2>/dev/null | head -1)"
command -v pip >/dev/null 2>&1 && echo "pip.version=$(pip --version 2>/dev/null | head -1)"
command -v pip3 >/dev/null 2>&1 && echo "pip3.version=$(pip3 --version 2>/dev/null | head -1)"
command -v node >/dev/null 2>&1 && echo "node.version=$(node -v 2>/dev/null)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "git.branch=$(git branch --show-current 2>/dev/null)"
  echo "git.changed=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  echo "git.last=$(git log -1 --format='%h %s' 2>/dev/null)"
fi
''';
  final facts = <String, String>{};
  try {
    final res = await Process.run(
      env.shell,
      ['-c', script],
      environment: env.env,
      workingDirectory: workingDir,
    ).timeout(const Duration(seconds: 8));
    for (final line in (res.stdout as String).split('\n')) {
      final eq = line.indexOf('=');
      if (eq > 0) facts[line.substring(0, eq)] = line.substring(eq + 1).trim();
    }
  } on Object {
    // Without the probe the block still names the folder and shell.
  }
  return formatEnvironment(workingDir: workingDir, shell: env.shell, facts: facts, today: DateTime.now());
}

/// The ENVIRONMENT block from the probe's [facts] (`key=value` lines).
String formatEnvironment({
  required String workingDir,
  required String shell,
  required Map<String, String> facts,
  required DateTime today,
}) {
  final out = StringBuffer('<ENVIRONMENT>\n')
    ..writeln('Working directory: $workingDir')
    ..writeln('Platform: ${facts['os'] ?? Platform.operatingSystem}; shell: $shell (your login environment)')
    ..writeln('Date: ${today.toIso8601String().substring(0, 10)}');
  if (facts['git.branch'] case final b?) {
    final changed = int.tryParse(facts['git.changed'] ?? '') ?? 0;
    final last = facts['git.last'] ?? '';
    out.writeln(
      'Git: branch ${b.isEmpty ? '(detached)' : b}, ${changed == 0 ? 'clean' : '$changed changed files'}'
      '${last.isEmpty ? '' : '; last commit $last'}',
    );
  } else {
    out.writeln('Git: not a repository');
  }
  final venv = facts['venv'] ?? '';
  if (venv.isNotEmpty) out.writeln('Active environment: $venv');
  final tools = [
    for (final t in const [
      'python3',
      'pip',
      'pip3',
      'uv',
      'node',
      'npm',
      'pnpm',
      'bun',
      'go',
      'cargo',
      'java',
      'flutter',
    ])
      if (facts['which.$t'] case final p?) '$t → $p',
  ];
  if (tools.isNotEmpty) out.writeln('On PATH: ${tools.join(', ')}');
  if (facts['python3.version'] case final v? when v.isNotEmpty) out.writeln('python3: $v');
  final pyPip = facts['python3.pip'] ?? '';
  if (pyPip.isNotEmpty) out.writeln('python3 -m pip: $pyPip');
  for (final p in const ['pip', 'pip3']) {
    final v = facts['$p.version'] ?? '';
    if (v.isEmpty) continue;
    out.writeln('$p: $v');
    final pipPython = _pythonOf(v), runPython = _pythonOf(pyPip);
    if (pipPython != null && runPython != null && pipPython != runPython) {
      out.writeln(
        'Warning: `$p` installs into Python $pipPython but `python3` is Python $runPython. Use `python3 -m pip` '
        '(or a project .venv) so packages land where the code runs.',
      );
    }
  }
  if (facts['node.version'] case final v? when v.isNotEmpty) out.writeln('node: $v');
  out.write('</ENVIRONMENT>');
  return out.toString();
}

/// "pip 24.0 from /…/site-packages/pip (python 3.9)" → "3.9".
String? _pythonOf(String pipVersion) => RegExp(r'\(python (\d+\.\d+)').firstMatch(pipVersion)?.group(1);
