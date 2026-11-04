import 'package:every_ai/features/code/domain/fork_files.dart';
import 'package:every_ai/features/code/domain/phases.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _call(Map<String, Object?> action, [String id = 'a']) =>
    ActionCall(id: id, raw: const {}, toolName: 'x', toolCallId: id, action: action);

ActionCall _edit(String path) => _call({'kind': 'EditAction', 'file_path': path});
ActionCall _bash(String command) => _call({'kind': 'TerminalAction', 'command': command});

void main() {
  const dir = '/p/os';

  test('paths are made relative to the folder, and ones outside it are dropped', () {
    expect(relativeTo('/p/os/index.html', dir), 'index.html');
    expect(relativeTo('/p/os/src/../games.js', '/p/os/'), 'games.js');
    expect(relativeTo('./src/a.js', dir), 'src/a.js');
    expect(relativeTo('/p/other/a.js', dir), isNull);
    expect(relativeTo('../a.js', dir), isNull);
  });

  test('what a subagent wrote is read from its events, in its own copy of the folder', () {
    final events = [
      _edit('/forks/f1/index.html'),
      _call({'kind': 'WriteFileAction', 'file_path': '/forks/f1/games.js'}),
      _call({'kind': 'FileEditorAction', 'command': 'view', 'path': '/forks/f1/README.md'}),
      _call({'kind': 'FileEditorAction', 'command': 'create', 'path': 'notes.md'}),
      _call({'kind': 'ReadFileAction', 'file_path': '/forks/f1/plan.md'}),
    ];
    expect(filesWritten(events, '/forks/f1'), {'index.html', 'games.js', 'notes.md'});
  });

  test('a refused or failed write claims nothing; one still running does', () {
    ToolResult result(String id, ToolOutcome outcome) =>
        ToolResult(id: 'r$id', raw: const {}, actionId: id, toolName: 'write', observation: const {}, outcome: outcome);
    final events = <HarnessEvent>[
      _call({'kind': 'WriteFileAction', 'file_path': '/p/os/.everyai/scratch/plan.md'}, 'w1'),
      result('w1', ToolOutcome.rejected),
      _call({'kind': 'WriteFileAction', 'file_path': '/p/os/index.html'}, 'w2'),
      result('w2', ToolOutcome.error),
      _call({'kind': 'WriteFileAction', 'file_path': '/p/os/games.js'}, 'w3'),
      result('w3', ToolOutcome.ok),
      _call({'kind': 'WriteFileAction', 'file_path': '/p/os/notes.md'}, 'w4'),
    ];
    expect(filesWritten(events, dir), {'games.js', 'notes.md'});
  });

  test('file names in a task are found, URLs and versions are not', () {
    expect(
      filesNamed('Build the desktop in index.html and put the games in src/games.js (see https://x.dev/a.js, v1.2).'),
      {'index.html', 'src/games.js'},
    );
  });

  test('the parent waits to edit a file a running subagent works on, and nothing else', () {
    final owned = {
      'Build desktop': {'index.html'},
    };
    expect(waitForSubagent(_edit('/p/os/index.html'), owned, dir), contains('"Build desktop"'));
    expect(waitForSubagent(_edit('index.html'), owned, dir), isNotNull);
    expect(waitForSubagent(_edit('/p/os/notes.md'), owned, dir), isNull);
    expect(waitForSubagent(_call({'kind': 'ReadFileAction', 'file_path': '/p/os/index.html'}), owned, dir), isNull);
    expect(waitForSubagent(_edit('/p/os/index.html'), const {}, dir), isNull);
  });

  test('a shell command that changes things and names the file waits; reading it does not', () {
    final owned = {
      'Build desktop': {'index.html'},
    };
    expect(
      waitForSubagent(_bash("python3 -c 'p=Path(\"index.html\"); p.write_text(x)'"), owned, dir),
      contains('index.html'),
    );
    expect(waitForSubagent(_bash('cat index.html | head -20'), owned, dir), isNull);
    expect(waitForSubagent(_bash('node build.js > out.txt'), owned, dir), isNull);
    expect(waitForSubagent(_bash('sed -i "" s/a/b/ old-index.html'), owned, dir), isNull);
  });

  test('before Build a Max flow writes only its own notes, and starts only lookers', () {
    expect(refusedBeforeBuild(_edit('/p/os/index.html'), Phase.plan, 'Max', dir), contains('plan phase'));
    expect(refusedBeforeBuild(_edit('/p/os/.everyai/scratch/plan.md'), Phase.plan, 'Max', dir), isNull);
    expect(refusedBeforeBuild(_edit('/p/os/index.html'), Phase.build, 'Max', dir), isNull);
    expect(refusedBeforeBuild(_edit('/p/os/index.html'), Phase.reproduce, 'Bug fix', dir), isNull);
    expect(refusedBeforeBuild(_bash('mkdir -p .everyai/scratch'), Phase.research, 'Ultra', dir), isNull);
    // A patch is refused for any project file it touches, not just its first.
    final patch = _call({
      'kind': 'ApplyPatchAction',
      'path': '/p/os/.everyai/scratch/notes.md',
      'paths': ['/p/os/.everyai/scratch/notes.md', '/p/os/index.html'],
    });
    expect(writeTargets(patch), hasLength(2));
    expect(refusedBeforeBuild(patch, Phase.plan, 'Max', dir), contains('plan phase'));

    expect(subagentBeforeBuild('', Phase.plan, 'Ultra'), contains('Not started'));
    expect(subagentBeforeBuild('researcher', Phase.research, 'Max'), isNull);
    expect(subagentBeforeBuild('reviewer', Phase.plan, 'Max'), isNull);
    expect(subagentBeforeBuild('', Phase.build, 'Max'), isNull);
  });
}
