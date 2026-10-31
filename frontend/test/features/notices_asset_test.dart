import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bundled third-party notices match the repository file', () {
    final root = File('../THIRD_PARTY_NOTICES.md').readAsStringSync();
    final bundled = File('assets/legal/THIRD_PARTY_NOTICES.md').readAsStringSync();
    expect(bundled, root, reason: 'Copy THIRD_PARTY_NOTICES.md to frontend/assets/legal/ after editing it.');
    expect(bundled, contains('Deno'));
  });
}
