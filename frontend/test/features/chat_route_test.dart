import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// [events] as the backend streams them.
SseTransport _transport(String events) => SseTransport(
  ApiClient(
    baseUrl: Uri.parse('http://test/'),
    client: MockClient((_) async => http.Response(events, 200, headers: {'content-type': 'text/event-stream'})),
  ),
);

void main() {
  test('route comes first; decide and summarise calls leave the context alone', () async {
    final events = await _transport(
      'event: route\ndata: {"model":"anthropic/claude-sonnet-5.5","mode":"search","tools_enabled":false}\n\n'
      'event: delta\ndata: {"text":"hi"}\n\n'
      'event: usage\ndata: {"kind":"decide","prompt_tokens":40,"charged_micros":3}\n\n'
      'event: usage\ndata: {"kind":"summarise","prompt_tokens":9000,"charged_micros":120}\n\n'
      'event: usage\ndata: {"kind":"chat","prompt_tokens":500,"charged_micros":90}\n\n'
      'event: done\ndata: {}\n\n',
    ).send(ChatRequest(model: autoModel, prompt: 'q')).toList();
    final route = events.first as RouteChosen;
    expect(
      (route.model, route.mode, route.toolsEnabled),
      (const ModelId('anthropic/claude-sonnet-5.5'), ChatMode.search, false),
    );
    expect(events.whereType<UsageReport>().map((u) => u.followUps), [true, true, false]);
  });

  test('a route without a mode keeps the requested one', () async {
    final events = await _transport('event: route\ndata: {"model":"openai/gpt-6.1-sol"}\n\nevent: done\ndata: {}\n\n')
        .send(ChatRequest(model: autoModel, prompt: 'q', mode: ChatMode.learn))
        .toList();
    final route = events.first as RouteChosen;
    expect((route.mode, route.toolsEnabled), (ChatMode.learn, true));
  });

  test('RoutePart round-trips through JSON', () {
    const part = RoutePart(model: ModelId('x/y'), mode: ChatMode.research, toolsEnabled: false);
    final back = RoutePart.fromJson(part.toJson())!;
    expect((back.model, back.mode, back.toolsEnabled), (part.model, part.mode, part.toolsEnabled));
    expect(RoutePart.fromJson({'mode': 'chat'}), isNull);
  });
}
