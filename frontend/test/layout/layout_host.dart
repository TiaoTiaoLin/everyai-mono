// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Hosts a screen or widget the way the app does for each design language, and pumps it at a given window size and
// text scale, collecting every layout problem (overflow, unbounded size, any FlutterError) instead of stopping at the
// first.

import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/theme/native_themes.dart';
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:material_ui/material_ui.dart' as m;

/// [child] in the app shell of [language] (dark, like the owner runs it), as `home`.
class LayoutHost extends StatelessWidget {
  const LayoutHost({super.key, required this.language, required this.child, this.brightness = Brightness.dark});

  final DesignLanguage language;
  final Brightness brightness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget tokens(BuildContext context, Widget? c) =>
        EveryThemeScope(theme: EveryTheme.resolve(language, brightness), child: c ?? const SizedBox.shrink());
    return switch (language) {
      DesignLanguage.cupertino => c.CupertinoApp(
        debugShowCheckedModeBanner: false,
        theme: cupertinoTheme(brightness),
        builder: tokens,
        home: child,
      ),
      DesignLanguage.macos => mac.MacosApp(
        debugShowCheckedModeBanner: false,
        theme: macosTheme(brightness),
        builder: tokens,
        home: child,
      ),
      DesignLanguage.fluent => f.FluentApp(
        debugShowCheckedModeBanner: false,
        theme: fluentTheme(brightness),
        builder: tokens,
        home: child,
      ),
      DesignLanguage.material || DesignLanguage.adwaita => m.MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: materialTheme(brightness, adwaita: language == DesignLanguage.adwaita),
        builder: tokens,
        home: child,
      ),
    };
  }
}

/// A settings section body as the settings modal shows it: its own scroll view in the panel, 8pt side padding.
class SettingsBodyHost extends StatelessWidget {
  const SettingsBodyHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: child);
}

/// Pumps [child] at [size] and [textScale] and returns every layout problem it hit, each prefixed with [where].
/// Leaves the tree empty afterwards.
Future<List<String>> sweepOne(
  WidgetTester tester, {
  required String where,
  required Size size,
  required double textScale,
  required Widget child,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  // macos_ui asks AppKit for system colours; the test host has no AppKit, so answer with a mid grey.
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('appkit_ui_element_colors'),
    (call) async => switch (call.method) {
      'getColorComponents' => <String, double>{
        for (final c in ((call.arguments as Map)['components'] as List? ?? const [])) '$c': 0.5,
        'redComponent': 0.5,
        'greenComponent': 0.5,
        'blueComponent': 0.5,
        'alphaComponent': 1,
        'hueComponent': 0.5,
        'saturationComponent': 0.5,
        'brightnessComponent': 0.5,
      },
      _ => null,
    },
  );
  final problems = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    // A plugin the test host doesn't have (macOS system colours): not a layout problem.
    if (details.exception is MissingPluginException) return;
    final first = details.exceptionAsString().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '?');
    final culprit = _culprit(details);
    problems.add('$where: $first${culprit == null ? '' : ' [$culprit]'}');
  };
  try {
    await tester.pumpWidget(child);
    // Let futures (DB reads, providers) land, then lay out again; never wait on endless animations.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  } on Object catch (e) {
    problems.add('$where: threw ${e.toString().split('\n').first}');
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    // Debounces and pollers the screen started run out before the next one.
    await tester.pump(const Duration(minutes: 10));
    FlutterError.onError = previous;
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }
  // takeException clears what the binding kept so the next run starts clean.
  if (tester.takeException() case final e?) {
    if (problems.isEmpty) problems.add('$where: ${e.toString().split('\n').first}');
  }
  return problems;
}

/// Where the widget the error names was made (the overflowing Row/Column/Flex): `Row lib/…/file.dart:line`, or the
/// package file when the app didn't make it.
String? _culprit(FlutterErrorDetails details) {
  final m = RegExp(r'error-causing widget was:[\s\S]*?\b(\w+):(file:\S+|package:\S+)').firstMatch(details.toString());
  if (m == null) return null;
  final at = m.group(2)!.replaceFirst(RegExp(r'^file://.*?/frontend/'), '').replaceFirst(RegExp(r':\d+$'), '');
  return '${m.group(1)} $at';
}
