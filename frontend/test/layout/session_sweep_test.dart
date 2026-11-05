// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Layout sweep of a Code session at its busiest moments: the scripted demo session (questions, approvals, an edit
// diff, a subagent, tests) on the real session screen, with Session info and Diff open in the panel, in every design
// language, at a wide, a medium, a narrow and a short window, with normal and large text.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/ui/console/console_state.dart';
import 'package:every_ai/features/code/ui/session_view.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'layout_host.dart';

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

const sizes = [Size(1280, 800), Size(900, 640), Size(600, 720), Size(420, 480)];
const textScales = [1.0, 1.6];
const languages = [DesignLanguage.cupertino, DesignLanguage.macos, DesignLanguage.material, DesignLanguage.fluent];

Future<T> _until<T>(T Function() read, bool Function(T) cond) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// The moments of a session the sweep looks at.
enum Stage { question, approval, done }

void main() {
  for (final stage in Stage.values) {
    for (final language in languages) {
      testWidgets('Code session (${stage.name}) · ${language.name} lays out everywhere', (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        late ProviderContainer container;
        late CodeSessionInfo info;
        await tester.runAsync(() async {
          final prefs = await Preferences.load(db);
          prefs['code.projects'] = jsonEncode([
            const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
          ]);
          container = ProviderContainer(
            overrides: [
              databaseProvider.overrideWithValue(db),
              preferencesProvider.overrideWithValue(prefs),
              harnessProvider.overrideWithValue(FakeHarness(step: Duration.zero)),
              modelCatalogProvider.overrideWith(_Catalog.new),
              apiClientProvider.overrideWithValue(
                ApiClient(
                  baseUrl: Uri.parse('http://backend/'),
                  client: MockClient((_) async => http.Response('no network in the layout sweep', 599)),
                ),
              ),
            ],
          );
          info = await container
              .read(codeSessionsProvider.notifier)
              .start(
                project: container.read(codeProjectsProvider).single,
                prompt:
                    'Add a decrement button next to the increment one, with tests, and explain the change in a long '
                    'paragraph so the transcript has a message that wraps over several lines on a narrow window.',
                model: 'anthropic/claude-haiku-5.5',
                mode: stage == Stage.done ? AgentMode.fullAuto : AgentMode.ask,
              );
          container.listen(codeSessionProvider(info.id), (_, _) {});
          if (stage == Stage.question) {
            await _until(() => container.read(codeSessionProvider(info.id)).transcript.openQuestion, (q) => q != null);
          } else if (stage == Stage.approval) {
            // Ask mode: answer the questions, then stop at the first approval card.
            final controller = container.read(codeSessionProvider(info.id).notifier);
            await _until(() {
              final state = container.read(codeSessionProvider(info.id));
              if (state.transcript.openQuestion case final q?) {
                unawaited(controller.answer(q, [for (final _ in q.questions) const QuestionAnswer(selected: {0})]));
              }
              return state.transcript.pending;
            }, (p) => p.isNotEmpty);
          } else {
            // Full auto still asks its questions; answer each (first option) until the run is done.
            final controller = container.read(codeSessionProvider(info.id).notifier);
            await _until(() {
              final state = container.read(codeSessionProvider(info.id));
              if (state.transcript.openQuestion case final q?) {
                unawaited(controller.answer(q, [for (final _ in q.questions) const QuestionAnswer(selected: {0})]));
              }
              return state.status;
            }, (s) => s == SessionStatus.done);
          }
        });

        final problems = <String>[];
        for (final view in [null, ConsoleView.info, ConsoleView.diff]) {
          for (final size in sizes) {
            for (final scale in textScales) {
              if (view == null) {
                container.read(consolePanelProvider(info.id).notifier).close();
              } else {
                container.read(consolePanelProvider(info.id).notifier).show(view);
              }
              problems.addAll(
                await sweepOne(
                  tester,
                  where:
                      'Code session ${stage.name} · panel ${view?.name ?? 'closed'} · ${language.name} · '
                      '${size.width.round()}×${size.height.round()} · ×$scale',
                  size: size,
                  textScale: scale,
                  child: UncontrolledProviderScope(
                    container: container,
                    child: LayoutHost(
                      language: language,
                      child: ShellScope(
                        sidebarVisible: size.width >= 760,
                        compact: size.width < 760,
                        toggleSidebar: () {},
                        child: CodeSessionScreen(sessionId: info.id),
                      ),
                    ),
                  ),
                ),
              );
            }
          }
        }
        await tester.runAsync(() async {
          container.dispose();
          await db.close();
        });
        for (final p in problems.toSet()) {
          debugPrint('LAYOUT: $p');
        }
        expect(problems.toSet().toList(), isEmpty, reason: problems.toSet().join('\n'));
      });
    }
  }
}
