import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/local_ports.dart';
import 'package:every_ai/features/code/panes/panes_providers.dart';
import 'package:every_ai/features/code/ui/console/console_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLsofListen', () {
    test('reads pids and listening sockets, skipping connections', () {
      const out =
          'p4242\nf21\nn*:3000\nf22\nn[::1]:3000\nf23\nn127.0.0.1:5000->127.0.0.1:61000\n'
          'p77\nf5\nn127.0.0.1:5173\n';
      expect(parseLsofListen(out), [
        const ListeningPort(pid: 4242, port: 3000, host: '*'),
        const ListeningPort(pid: 4242, port: 3000, host: '::1'),
        const ListeningPort(pid: 77, port: 5173, host: '127.0.0.1'),
      ]);
    });

    test('ignores junk and empty output', () {
      expect(parseLsofListen(''), isEmpty);
      expect(parseLsofListen('nfoo:bar\np\nn*:99999'), isEmpty);
    });
  });

  test('parseSsListen reads the local address and every pid', () {
    const out =
        'LISTEN 0      511        127.0.0.1:5173      0.0.0.0:*    users:(("node",pid=1234,fd=20))\n'
        'LISTEN 0      4096            [::]:8080         [::]:*    users:(("python3",pid=9,fd=3),("python3",pid=10,fd=3))\n'
        'LISTEN 0      128   127.0.0.53%lo:53         0.0.0.0:*\n';
    expect(parseSsListen(out), [
      const ListeningPort(pid: 1234, port: 5173, host: '127.0.0.1'),
      const ListeningPort(pid: 9, port: 8080, host: '::'),
      const ListeningPort(pid: 10, port: 8080, host: '::'),
    ]);
  });

  test('ListeningPort.local', () {
    for (final h in ['*', '0.0.0.0', '::', '::1', '127.0.0.1']) {
      expect(ListeningPort(pid: 1, port: 1, host: h).local, isTrue, reason: h);
    }
    expect(const ListeningPort(pid: 1, port: 1, host: '192.168.1.4').local, isFalse);
  });

  group('detectLocalUrls', () {
    test('finds dev server addresses through colour codes', () {
      const vite =
          '\x1B[32m  VITE v5.0.0\x1B[39m  ready in 300 ms\n\n'
          '  \x1B[32m➜\x1B[39m  \x1B[1mLocal\x1B[22m:   \x1B[36mhttp://localhost:\x1B[1m5173\x1B[22m/\x1B[39m\n'
          '  ➜  Network: use --host to expose\n';
      // The port is split by a bold escape; stripping it joins the URL.
      expect(detectLocalUrls(vite), ['http://localhost:5173/']);
    });

    test('normalizes loopback and wildcard hosts, drops trailing punctuation', () {
      const text =
          'Serving on http://0.0.0.0:8000.\n'
          '- Local: http://127.0.0.1:3000/app, see docs\n'
          'Listening at http://[::1]:4000\n'
          'Also https://localhost:8443/secure;\n'
          'Not this: https://example.com:3000/\n';
      expect(detectLocalUrls(text), [
        'http://localhost:8000/',
        'http://localhost:3000/app',
        'http://localhost:4000/',
        'https://localhost:8443/secure',
      ]);
    });

    test('a repeated URL moves to the end', () {
      expect(detectLocalUrls('http://localhost:1/ then http://localhost:2/ then http://localhost:1/'), [
        'http://localhost:2/',
        'http://localhost:1/',
      ]);
    });
  });

  test('normalizePreviewUrl', () {
    expect(normalizePreviewUrl(''), isNull);
    expect(normalizePreviewUrl(' 3000 '), 'http://localhost:3000/');
    expect(normalizePreviewUrl(':8080'), 'http://localhost:8080/');
    expect(normalizePreviewUrl(':8080/x'), 'http://localhost:8080/x');
    expect(normalizePreviewUrl('localhost:5173/a'), 'http://localhost:5173/a');
    expect(normalizePreviewUrl('https://localhost:1/'), 'https://localhost:1/');
  });

  test('previewCandidates puts printed URLs first, then unclaimed local ports', () {
    final out = previewCandidates(
      printed: ['http://localhost:5173/', 'http://localhost:3000/app'],
      ports: const [
        ListeningPort(pid: 1, port: 9229, host: '127.0.0.1'),
        ListeningPort(pid: 2, port: 3000),
        ListeningPort(pid: 3, port: 6000, host: '10.0.0.2'),
        ListeningPort(pid: 4, port: 9229, host: '::1'),
      ],
    );
    expect(out, ['http://localhost:3000/app', 'http://localhost:5173/', 'http://localhost:9229/']);
  });

  group('drawer state', () {
    ProviderContainer containerWith(Preferences prefs) {
      final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      return c;
    }

    test('starts closed, toggles, and remembers the last tab', () {
      final c = containerWith(Preferences.inMemory());
      final drawer = c.read(codePaneProvider('s').notifier);
      expect(c.read(codePaneProvider('s')).open, isNull);
      drawer.toggleDrawer();
      expect(c.read(codePaneProvider('s')).open, CodePane.terminal);
      drawer.show(CodePane.preview);
      drawer.toggle(CodePane.preview);
      expect(c.read(codePaneProvider('s')).open, isNull);
      drawer.toggleDrawer();
      expect(c.read(codePaneProvider('s')).open, CodePane.preview);
      expect(c.read(codePaneProvider('other')).open, isNull);
    });

    test("each session remembers its drawer next to the panel's keys; deleting the session forgets both", () async {
      final prefs = Preferences.inMemory();
      prefs['code.sessions'] = jsonEncode([
        CodeSessionInfo(
          id: 'a',
          projectId: 'p1',
          title: 'A',
          conversationId: 'c',
          model: 'm',
          mode: AgentMode.ask,
          workingDir: '/tmp/x',
          createdAt: DateTime(2026),
        ).toJson(),
      ]);
      final first = containerWith(prefs);
      first.read(consolePanelProvider('a').notifier).show(ConsoleView.diff);
      first.read(codePaneProvider('a').notifier)
        ..show(CodePane.processes)
        ..setHeight(180, persist: false)
        ..setHeight(310);
      first.read(consolePanelProvider('a').notifier).setWidth(500);
      expect(jsonDecode(prefs['${codeLayoutPrefix}a']!), {
        'panel': 'diff',
        'panel_width': 500,
        'drawer': 'processes',
        'drawer_last': 'processes',
        'drawer_height': 310,
      });

      final again = containerWith(prefs);
      expect(again.read(codePaneProvider('a')).open, CodePane.processes);
      expect(again.read(codePaneProvider('a')).height, 310);
      expect(again.read(consolePanelProvider('a')).view, ConsoleView.diff);
      // Closed, it still opens on the last tab.
      again.read(codePaneProvider('a').notifier).close();
      expect(containerWith(prefs).read(codePaneProvider('a')).last, CodePane.processes);

      await again.read(codeSessionsProvider.notifier).remove('a');
      expect(prefs['${codeLayoutPrefix}a'], isNull);
    });
  });
}
