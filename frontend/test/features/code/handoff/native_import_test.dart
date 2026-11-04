import 'package:every_ai/features/code/handoff/native/claude_import.dart';
import 'package:every_ai/features/code/handoff/native/codex_import.dart';
import 'package:every_ai/features/code/handoff/native/opencode_import.dart';
import 'package:every_ai/features/code/handoff/native_import.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_source.dart';

void main() {
  test('Claude Code, Codex and OpenCode take an import; ACP agents, terminals and EveryAI do not', () {
    expect(nativeImporterFor('claude-code'), isA<ClaudeImporter>());
    expect(nativeImporterFor('codex'), isA<CodexImporter>());
    expect(nativeImporterFor('opencode'), isA<OpenCodeImporter>());
    for (final id in ['claude-code', 'codex', 'opencode']) {
      expect(nativeImporterFor(id)!.harness, id);
    }
    for (final id in ['everyai', 'acp:gemini', 'acp:cursor', 'terminal:aider']) {
      expect(nativeImporterFor(id), isNull, reason: id);
    }
  });

  test('without a session tag no importer writes anything', () async {
    for (final id in ['claude-code', 'codex', 'opencode']) {
      expect(
        await nativeImporterFor(id)!.write(source(sessionTag: '', model: 'a/b')),
        isNull,
        reason: id,
      );
    }
  });
}
