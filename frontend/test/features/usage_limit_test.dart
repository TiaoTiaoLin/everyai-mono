import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a usage-limit event round-trips and stays a plain failure', () {
    final at = DateTime.utc(2026, 11, 5, 3);
    final e = usageLimitEvent('e1', 'You hit your 5-hour limit.', resetsAt: at);
    expect(e.message, 'You hit your 5-hour limit.');
    final decoded = HarnessEvent.decode(e.raw);
    expect(usageLimitOf(decoded)?.resetsAt, at);
    expect(usageLimitOf(HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': 'x', 'detail': 'boom'})), isNull);
  });
}
