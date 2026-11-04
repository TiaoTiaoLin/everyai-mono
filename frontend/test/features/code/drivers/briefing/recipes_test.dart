import 'dart:convert';

import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart';
import 'package:every_ai/features/code/drivers/briefing/recipes.dart';
import 'package:flutter_test/flutter_test.dart';

import '_fixtures.dart';

void main() {
  final i = input();
  const skills = [(name: 'make-deck', description: 'Builds decks.')];

  test('claude code: session plugin, http MCP with an env-var header, session text as system prompt', () {
    final d = claudeCode(i);
    expect(d.args.sublist(0, 2), ['--plugin-dir', '/data/s1/briefing']);
    final mcp = jsonDecode(d.args[d.args.indexOf('--mcp-config') + 1]) as Map;
    expect(mcp, {
      'mcpServers': {
        'everyai': {
          'type': 'http',
          'url': 'http://127.0.0.1:5123/mcp',
          'headers': {'Authorization': r'Bearer ${EVERYAI_MCP_TOKEN}'},
        },
      },
    });
    expect(d.args[d.args.indexOf('--append-system-prompt') + 1], i.sessionText);
    expect(jsonDecode(d.args[d.args.indexOf('--settings') + 1]), {'disableSkillShellExecution': true});
    expect(d.args, containsAllInOrder(['--add-dir', '/data/s1/briefing/skills']));
    expect(d.args, isNot(contains('--strict-mcp-config')));
    expect(d.env, {'EVERYAI_MCP_TOKEN': 'tok-SECRET-123'});
    expect(claudeCode(i, strictMcp: true).args, contains('--strict-mcp-config'));
    expect(claudeCode(i, grantSkillAccess: false).args, isNot(contains('--add-dir')));
  });

  test('codex: -c overrides, skill root by app-server request, the session text as instructions', () {
    final d = codex(i);
    expect(d.args, [
      '-c',
      'mcp_servers.everyai.url="http://127.0.0.1:5123/mcp"',
      '-c',
      'mcp_servers.everyai.bearer_token_env_var="EVERYAI_MCP_TOKEN"',
    ]);
    expect(d.env, {'EVERYAI_MCP_TOKEN': 'tok-SECRET-123'});
    expect(d.initRequests, hasLength(1));
    expect(d.initRequests.single.method, 'skills/extraRoots/set');
    expect(d.initRequests.single.params, {
      'extraRoots': ['/data/s1/briefing/skills'],
    });
    expect(d.instructions, i.sessionText);
    expect(d.args.join(' '), isNot(contains('CODEX_HOME')));
  });

  test('opencode: inline config with the native MCP shape, header by env substitution', () {
    final d = openCode(i);
    expect(d.args, isEmpty);
    expect(d.env['EVERYAI_MCP_TOKEN'], 'tok-SECRET-123');
    final cfg = jsonDecode(d.env['OPENCODE_CONFIG_CONTENT']!) as Map;
    final server = ((cfg['mcp'] as Map)['servers'] as Map)['everyai'] as Map;
    expect(server['type'], 'remote');
    expect(server['url'], 'http://127.0.0.1:5123/mcp');
    expect(server['disabled'], false);
    expect((server['headers'] as Map)['Authorization'], 'Bearer {env:EVERYAI_MCP_TOKEN}');
    expect(cfg['skills'], ['/data/s1/briefing/skills']);
    // The session text is a plain file beside skills/, so it is not also discoverable as a skill.
    expect(cfg['instructions'], ['/data/s1/briefing/session.md']);
    // The config carries the variable name, never the token.
    expect(d.env['OPENCODE_CONFIG_CONTENT'], isNot(contains('tok-SECRET-123')));
  });

  test('gemini: acp flags and an inline briefing with skill paths', () {
    final d = gemini(i, skills: skills);
    expect(d.args, ['--acp', '--include-directories', '/data/s1/briefing/skills']);
    expect(d.env, isEmpty);
    expect(d.firstPrompt, contains('Body text.'));
    expect(d.firstPrompt, contains('- make-deck: Builds decks. (`/data/s1/briefing/skills/make-deck/SKILL.md`)'));
    expect(gemini(i).firstPrompt, isNot(contains('## Skills')));
  });

  test('acp: session/new entry with a header list; the inline briefing is shared', () {
    expect(acpMcpServer(i), {
      'type': 'http',
      'name': 'everyai',
      'url': 'http://127.0.0.1:5123/mcp',
      'headers': [
        {'name': 'Authorization', 'value': 'Bearer tok-SECRET-123'},
      ],
    });
    expect(acp(i, skills: skills).firstPrompt, gemini(i, skills: skills).firstPrompt);
    expect(acp(i).args, isEmpty);
  });

  test('the token is never an argument, and no path points into a CLI home', () {
    final all = <Delivery>[claudeCode(i, strictMcp: true), codex(i), openCode(i), gemini(i, skills: skills), acp(i)];
    for (final d in all) {
      final text = [...d.args, ...d.initRequests.map((r) => jsonEncode(r.params))].join('\n');
      expect(text, isNot(contains('tok-SECRET-123')));
      for (final home in ['.claude', '.codex', '.config/opencode', '.gemini']) {
        expect(text, isNot(contains(home)), reason: home);
        expect(d.env['OPENCODE_CONFIG_CONTENT'] ?? '', isNot(contains(home)));
      }
    }
  });

  test('briefingRootOf is the folder above skills', () {
    expect(briefingRootOf('/a/b/briefing/skills'), '/a/b/briefing');
    expect(briefingRootOf('/a/b/briefing/skills/'), '/a/b/briefing');
  });
}
