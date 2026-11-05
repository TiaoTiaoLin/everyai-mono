import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/chat/ui/link_gate.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  Future<List<Uri>> pumpLink(WidgetTester tester, Uri uri) async {
    final launched = <Uri>[];
    await tester.pumpWidget(
      m.MaterialApp(
        builder: (context, child) =>
            EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
        home: Builder(
          builder: (context) => m.Material(
            child: m.TextButton(
              onPressed: () => openOutside(
                context,
                uri,
                launch: (u) async {
                  launched.add(u);
                  return true;
                },
              ),
              child: const Text('link'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();
    return launched;
  }

  testWidgets('an ordinary link opens with no question', (tester) async {
    final uri = Uri.parse('https://docs.flutter.dev/ui');
    expect(await pumpLink(tester, uri), [uri]);
    expect(find.textContaining('Open docs.flutter.dev'), findsNothing);
  });

  testWidgets('a link carrying data shows the real host and address first', (tester) async {
    final uri = Uri.parse('https://evil.example/c?d=${'aGVsbG8gd29ybGQ' * 5}');
    final launched = await pumpLink(tester, uri);
    expect(launched, isEmpty);
    expect(find.text('Open evil.example?'), findsOneWidget);
    expect(find.textContaining('long block of data'), findsOneWidget);
    expect(find.textContaining(uri.toString()), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(launched, isEmpty);

    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(launched, [uri]);
  });
}
