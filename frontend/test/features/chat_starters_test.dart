import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/chat/domain/starters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starter chips pick the mode that suits them and keep a prefill', () {
    final modes = {for (final s in chatStarters) s.label: s.mode};
    expect(modes, {
      'Write': ChatMode.chat,
      'Learn': ChatMode.learn,
      'Code': ChatMode.chat,
      'Research': ChatMode.research,
      'Summarize': ChatMode.summarise,
    });
    for (final s in chatStarters) {
      expect(s.prompt, endsWith(' '), reason: '${s.label} leaves room to type');
    }
  });
}
