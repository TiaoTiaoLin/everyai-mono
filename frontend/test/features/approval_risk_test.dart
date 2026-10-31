import 'dart:convert';

import 'package:every_ai/core/api/decide_client.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/approval_risk.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/ui/transcript/approval_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart' as m;

class _Store implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

DecideResult _answers(Map<String, Object?> values) => DecideResult.fromJson({
  'answers': [
    for (final e in values.entries) {'id': e.key, 'value': e.value},
  ],
}, riskQuestions);

void main() {
  group('riskLabel', () {
    test('reads the four answers as one line', () {
      expect(riskLabel(_answers({'read_only': true, 'destructive': false})), 'Looks read-only');
      expect(
        riskLabel(_answers({'read_only': false, 'destructive': true, 'network': true})),
        'May delete files · uses the network',
      );
      expect(riskLabel(_answers({'read_only': false, 'network': true})), 'Uses the network');
      expect(
        riskLabel(_answers({'read_only': true, 'outside_project': true})),
        'Looks read-only · reaches outside the project',
      );
      expect(riskLabel(_answers({'read_only': false, 'destructive': false})), 'Changes files in the project');
      expect(riskLabel(_answers({'read_only': 'unsure', 'destructive': false})), 'Unsure');
      expect(riskLabel(_answers(const {})), 'Unsure');
    });

    test('a failed call has no label', () {
      expect(riskLabel(DecideResult.unsure(riskQuestions)), isNull);
    });
  });

  group('approvalRiskProvider', () {
    late List<http.Request> sent;
    late http.Response Function() reply;

    ProviderContainer container() {
      sent = [];
      final c = ProviderContainer(
        overrides: [
          decideClientProvider.overrideWithValue(
            DecideClient(
              ApiClient(
                baseUrl: Uri.parse('http://test/'),
                client: MockClient((req) async {
                  sent.add(req);
                  return reply();
                }),
              ),
              authenticated: true,
            ),
          ),
          gatewayKeysProvider.overrideWithValue(GatewayKeys(store: _Store(), mint: () async => 'sk-eai-test')),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    const key = (command: 'rm -rf build', workingDir: '/work/app', session: 's1');

    test('asks once on the gateway key, with job risk, and keeps the label', () async {
      reply = () => http.Response(
        jsonEncode({
          'answers': [
            {'id': 'read_only', 'value': false},
            {'id': 'destructive', 'value': true},
          ],
        }),
        200,
      );
      final c = container();
      expect(await c.read(approvalRiskProvider(key).future), 'May delete files');
      final body = jsonDecode(sent.single.body) as Map<String, Object?>;
      expect(body['job'], 'risk');
      expect(body['text'], contains('rm -rf build'));
      expect(body['text'], contains('/work/app'));
      expect(sent.single.headers['Authorization'], 'Bearer sk-eai-test');
      expect(sent.single.headers['X-EveryAI-Session'], 's1');
      expect(await c.read(approvalRiskProvider(key).future), 'May delete files');
      expect(sent, hasLength(1));
    });

    test('a failure gives no label', () async {
      reply = () => http.Response(jsonEncode({'code': 'out_of_credits', 'message': 'no'}), 402);
      expect(await container().read(approvalRiskProvider(key).future), isNull);
    });

    testWidgets('the card shows the label under the command, and nothing without a working dir', (tester) async {
      reply = () => http.Response(
        jsonEncode({
          'answers': [
            {'id': 'read_only', 'value': true},
          ],
        }),
        200,
      );
      final c = container();
      final call = HarnessEvent.decode({
        'kind': 'ActionEvent',
        'id': 'a',
        'tool_name': 'bash',
        'action': {'kind': 'TerminalAction', 'command': 'ls -la'},
      }) as ActionCall;
      Widget card(String? dir) => UncontrolledProviderScope(
        container: c,
        child: m.MaterialApp(
          home: m.Material(
            child: EveryThemeScope(
              theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
              child: ApprovalCard(
                pending: [call],
                mode: AgentMode.ask,
                onAllow: (_) {},
                onDeny: (_) {},
                onMode: (_) {},
                workingDir: dir,
                session: 's1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(card(null));
      await tester.pumpAndSettle();
      expect(find.text('Looks read-only'), findsNothing);
      expect(sent, isEmpty);

      await tester.pumpWidget(card('/work/app'));
      await tester.runAsync(
        () => c.read(approvalRiskProvider((command: 'ls -la', workingDir: '/work/app', session: 's1')).future),
      );
      await tester.pumpAndSettle();
      expect(find.text('Looks read-only'), findsOneWidget);
    });
  });
}
