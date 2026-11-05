import 'package:every_ai/features/code/ui/console/console_state.dart';
import 'package:every_ai/features/code/ui/transcript/transcript_items.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('displayPath', () {
    test('is relative inside the session folder', () {
      expect(displayPath('/Users/a/proj/src/main.py', '/Users/a/proj'), 'src/main.py');
      expect(displayPath('/Users/a/proj/src/main.py', '/Users/a/proj/'), 'src/main.py');
      expect(displayPath('/Users/a/proj', '/Users/a/proj'), '.');
    });

    test('uses ~ under the home folder and leaves other paths alone', () {
      expect(displayPath('/Users/a/other/x.txt', '/Users/a/proj', home: '/Users/a'), '~/other/x.txt');
      expect(displayPath('/tmp/x.txt', '/Users/a/proj', home: '/Users/a'), '/tmp/x.txt');
      expect(displayPath('/Users/a/projector/x', '/Users/a/proj'), '/Users/a/projector/x');
    });
  });

  test('the console fits the width it has: panel beside, then over the transcript, then icons in the menu', () {
    expect(ConsoleTier.forWidth(1400), ConsoleTier.wide);
    expect(ConsoleTier.forWidth(1000), ConsoleTier.wide);
    expect(ConsoleTier.forWidth(900), ConsoleTier.medium);
    expect(ConsoleTier.forWidth(700), ConsoleTier.medium);
    expect(ConsoleTier.forWidth(650), ConsoleTier.narrow);
  });
}
