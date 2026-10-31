import 'dart:async';
import 'dart:convert';

import 'package:every_ai/core/api/decide_client.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _questions = [
  DecideQuestion.yesNo('read_only', 'Does it only read?'),
  DecideQuestion.choice('lang', 'Which language?', ['en', 'fr']),
  DecideQuestion.score('urgency', 'How urgent?'),
];

DecideClient _client(Future<http.Response> Function(http.Request) handler, {Duration? timeout}) => DecideClient(
  ApiClient(baseUrl: Uri.parse('http://test/'), client: MockClient(handler)),
  timeout: timeout ?? const Duration(seconds: 8),
);

void main() {
  test('parses typed answers and sends the questions', () async {
    late http.Request sent;
    final client = _client((req) async {
      sent = req;
      return http.Response(
        jsonEncode({
          'answers': [
            {'id': 'read_only', 'value': true, 'p': 0.93},
            {'id': 'lang', 'value': 'fr'},
            {'id': 'urgency', 'value': 0.25},
          ],
          'model': 'google/gemini-3.5-flash-lite',
          'charged_micros': 12,
        }),
        200,
      );
    });
    final r = await client.decide(job: 'risk', text: 'ls', questions: _questions, apiKey: 'sk-eai-x', session: 's1');
    expect(sent.url.path, '/v1/aux/decide');
    expect(sent.headers['Authorization'], 'Bearer sk-eai-x');
    expect(sent.headers['X-EveryAI-Session'], 's1');
    final body = jsonDecode(sent.body) as Map<String, Object?>;
    expect(body['job'], 'risk');
    expect((body['questions'] as List)[1], {
      'id': 'lang',
      'kind': 'choice',
      'prompt': 'Which language?',
      'choices': ['en', 'fr'],
    });
    expect(r.failed, isFalse);
    expect(r['read_only'].asBool, isTrue);
    expect(r['read_only'].p, 0.93);
    expect(r['lang'].asChoice, 'fr');
    expect(r['urgency'].asScore, 0.25);
    expect(r.model, 'google/gemini-3.5-flash-lite');
    expect(r.chargedMicros, 12);
  });

  test('"unsure", wrong types, unoffered choices and missing answers are unsure', () async {
    final client = _client(
      (_) async => http.Response(
        jsonEncode({
          'answers': [
            {'id': 'read_only', 'value': 'unsure'},
            {'id': 'lang', 'value': 'de'},
            {'id': 'urgency', 'value': 3},
          ],
        }),
        200,
      ),
    );
    final r = await client.decide(text: 'x', questions: [..._questions, const DecideQuestion.yesNo('gone', '?')]);
    expect(r.failed, isFalse);
    expect(r.allUnsure, isTrue);
    expect(r['never_asked'].unsure, isTrue);
  });

  test('errors, 402 and timeouts make every answer unsure', () async {
    for (final response in [
      http.Response(jsonEncode({'message': 'Out of credits', 'code': 'out_of_credits'}), 402),
      http.Response('boom', 500),
      http.Response('not json', 200),
    ]) {
      final r = await _client((_) async => response).decide(text: 'x', questions: _questions);
      expect(r.failed, isTrue);
      expect(r.allUnsure, isTrue);
      expect(r.answers.map((a) => a.id), ['read_only', 'lang', 'urgency']);
    }
    final never = Completer<http.Response>();
    final slow = await _client(
      (_) => never.future,
      timeout: const Duration(milliseconds: 20),
    ).decide(text: 'x', questions: _questions);
    expect(slow.failed, isTrue);
    expect(slow['read_only'].unsure, isTrue);
  });
}
