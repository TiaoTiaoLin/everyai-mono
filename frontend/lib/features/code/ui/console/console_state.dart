import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/preferences.dart';
import '../../panes/panes_providers.dart' show readCodeLayout, writeCodeLayout;

/// What the session console's right panel shows.
enum ConsoleView {
  info('Session info'),
  diff('Diff'),
  files('Files');

  const ConsoleView(this.label);
  final String label;
}

/// How the console fits the width the session screen really has (the sidebar takes part of the window).
enum ConsoleTier {
  /// The panel sits beside the transcript.
  wide,

  /// The panel lies over the transcript, on the right.
  medium,

  /// As [medium], and the header's view icons fold into its ⋯ menu.
  narrow;

  static ConsoleTier forWidth(double width) => width >= 1000
      ? wide
      : width >= 700
      ? medium
      : narrow;
}

/// The right panel of one session: its view (null: closed) and width, both remembered per session, plus what is
/// shown for now only: a child session's chat over the view, a file the Diff should scroll to, a jump to Running work.
@immutable
final class ConsolePanel {
  const ConsolePanel({this.view, this.width, this.child, this.focus, this.focusSeq = 0, this.runningSeq = 0});

  final ConsoleView? view;

  /// Null: the default share of the window.
  final double? width;

  /// A fork's, subagent's or workflow agent's session, opened from Running work (Back returns to the view).
  final String? child;

  /// The file the Diff should scroll to (absolute or repo-relative); [focusSeq] changes on every request, so asking
  /// twice scrolls twice.
  final String? focus;
  final int focusSeq;

  /// Changes when Session info should scroll to Running work (the ⋯ menu's Background tasks).
  final int runningSeq;

  bool get open => view != null;

  ConsolePanel _with({
    required ConsoleView? view,
    String? child,
    double? width,
    String? focus,
    int? focusSeq,
    int? runningSeq,
  }) => ConsolePanel(
    view: view,
    width: width ?? this.width,
    child: child,
    focus: focus ?? this.focus,
    focusSeq: focusSeq ?? this.focusSeq,
    runningSeq: runningSeq ?? this.runningSeq,
  );
}

final consolePanelProvider = NotifierProvider.family<ConsolePanels, ConsolePanel, String>(ConsolePanels.new);

/// A session's right panel. Stored in Preferences `code.layout.<id>` as `{"panel": "info"|"diff"|"files"|null,
/// "panel_width": 520}` next to the bottom drawer's keys ([readCodeLayout]); a session opened for the first time
/// shows Session info, and one the user closed stays closed.
final class ConsolePanels extends Notifier<ConsolePanel> {
  ConsolePanels(this.sessionId);
  final String sessionId;

  @override
  ConsolePanel build() {
    final j = readCodeLayout(ref.read(preferencesProvider), sessionId);
    if (!j.containsKey('panel')) return ConsolePanel(view: ConsoleView.info, width: _width(j));
    return ConsolePanel(view: ConsoleView.values.asNameMap()[j['panel']], width: _width(j));
  }

  static double? _width(Map<String, Object?> j) => (j['panel_width'] as num?)?.toDouble();

  void _save() => writeCodeLayout(ref.read(preferencesProvider), sessionId, {
    'panel': state.view?.name,
    'panel_width': state.width?.round(),
  });

  void show(ConsoleView view) {
    state = state._with(view: view);
    _save();
  }

  /// Opens [view], or closes the panel when [view] is the one showing (clicking the active icon).
  void toggle(ConsoleView view) => state.view == view ? close() : show(view);

  void close() {
    state = state._with(view: null);
    _save();
  }

  /// Opens the Diff scrolled to [path].
  void showDiff(String path) {
    state = state._with(view: ConsoleView.diff, focus: path, focusSeq: state.focusSeq + 1);
    _save();
  }

  /// The [ConsolePanel.runningSeq] Session info last scrolled for; kept here, since the view is often built fresh
  /// by the very request.
  int _ranTo = 0;

  /// Whether Session info still owes a scroll to Running work; true once per [showRunningWork].
  bool takeRunningJump() {
    if (state.runningSeq == _ranTo) return false;
    _ranTo = state.runningSeq;
    return true;
  }

  /// Opens Session info at Running work.
  void showRunningWork() {
    state = state._with(view: ConsoleView.info, runningSeq: state.runningSeq + 1);
    _save();
  }

  /// Shows [childId]'s chat over the current view (Session info if closed).
  void openChild(String childId) {
    state = state._with(view: state.view ?? ConsoleView.info, child: childId);
    _save();
  }

  /// Leaves the child's chat for the view under it.
  void back() => state = state._with(view: state.view);

  /// A new width (null: the default); [persist] is false while dragging, true at the end.
  void setWidth(double? width, {bool persist = true}) {
    state = ConsolePanel(
      view: state.view,
      width: width,
      child: state.child,
      focus: state.focus,
      focusSeq: state.focusSeq,
      runningSeq: state.runningSeq,
    );
    if (persist) _save();
  }
}
