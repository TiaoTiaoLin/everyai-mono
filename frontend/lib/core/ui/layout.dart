// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Layout building blocks that behave like CSS flexbox: they take whatever room their parent gives and never overflow
// it. Screens compose these instead of bare Rows and Columns where the content can outgrow the space (text that
// grows with the font size, buttons next to text, a centered block on a short window).

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [child] centered when it fits, scrolling when it doesn't (CSS: `min-height: 100%; overflow: auto` with centered
/// content). Never overflows a short window. [maxWidth] caps the content's width; [padding] goes around it.
class CenteredScroll extends StatelessWidget {
  const CenteredScroll({
    super.key,
    required this.child,
    this.maxWidth = double.infinity,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => !box.maxHeight.isFinite
        // Already inside a scroll view (a list): no scroll view of its own, just the padded, centered content.
        ? Padding(
            padding: padding,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: child,
              ),
            ),
          )
        : SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              // The viewport's height minus the padding, so a short child still centers vertically.
              constraints: BoxConstraints(
                minHeight: box.maxHeight.isFinite
                    ? (box.maxHeight - padding.resolve(Directionality.of(context)).vertical).clamp(0, double.infinity)
                    : 0,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: child,
                ),
              ),
            ),
          ),
  );
}

/// [lead] (text, a title block) and [actions] (buttons, a picker) on one line when the actions fit beside at least
/// [minLead] of lead; otherwise the actions wrap onto their own line(s) below the lead (CSS: `flex-wrap: wrap`).
/// Measured, not guessed: it holds for any label, text scale or font. The lead takes the rest of the line and should
/// wrap or ellipsize itself.
class WrapRow extends StatelessWidget {
  const WrapRow({
    super.key,
    required this.lead,
    this.actions = const [],
    this.gap = 8,
    this.minLead = 140,
    this.alignEnd = true,
  });

  final Widget lead;
  final List<Widget> actions;
  final double gap;

  /// The narrowest the lead may get before the actions go below it.
  final double minLead;

  /// Wrapped actions line up at the end (right in LTR), like a dialog's buttons.
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return lead;
    return _WrapRow(
      gap: gap,
      minLead: minLead,
      children: [
        lead,
        Wrap(
          spacing: gap,
          runSpacing: gap,
          alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        ),
      ],
    );
  }
}

class _WrapRow extends MultiChildRenderObjectWidget {
  const _WrapRow({required this.gap, required this.minLead, required super.children});
  final double gap;
  final double minLead;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWrapRow(gap: gap, minLead: minLead, textDirection: Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, _RenderWrapRow renderObject) => renderObject
    ..gap = gap
    ..minLead = minLead
    ..textDirection = Directionality.of(context);
}

class _WrapRowData extends ContainerBoxParentData<RenderBox> {}

class _RenderWrapRow extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _WrapRowData>, RenderBoxContainerDefaultsMixin<RenderBox, _WrapRowData> {
  _RenderWrapRow({required double gap, required double minLead, required TextDirection textDirection})
    : _gap = gap, // ignore: prefer_initializing_formals
      _minLead = minLead, // ignore: prefer_initializing_formals
      _textDirection = textDirection; // ignore: prefer_initializing_formals

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _minLead;
  set minLead(double v) {
    if (v == _minLead) return;
    _minLead = v;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _WrapRowData) child.parentData = _WrapRowData();
  }

  RenderBox get _lead => firstChild!;
  RenderBox get _actions => lastChild!;

  /// The actions' width on one line, and whether they fit beside [minLead] of lead in [width].
  bool _oneLine(double width) {
    final wanted = _actions.getMaxIntrinsicWidth(double.infinity);
    return !width.isFinite || wanted + _gap + _minLead <= width;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      [_lead.getMinIntrinsicWidth(height), _actions.getMinIntrinsicWidth(height)].reduce((a, b) => a > b ? a : b);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _lead.getMaxIntrinsicWidth(height) + _gap + _actions.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => _heightFor(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _heightFor(width);

  double _heightFor(double width) {
    if (_oneLine(width)) {
      final actionsWidth = _actions.getMaxIntrinsicWidth(double.infinity);
      final a = _actions.getMaxIntrinsicHeight(actionsWidth);
      final l = _lead.getMaxIntrinsicHeight((width - actionsWidth - _gap).clamp(0, double.infinity));
      return a > l ? a : l;
    }
    return _lead.getMaxIntrinsicHeight(width) + _gap + _actions.getMaxIntrinsicHeight(width);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    Size measure(RenderBox child, BoxConstraints c) =>
        dry ? child.getDryLayout(c) : (child..layout(c, parentUsesSize: true)).size;
    if (_oneLine(width)) {
      final actions = measure(_actions, BoxConstraints(maxWidth: width.isFinite ? width : double.infinity));
      final leadWidth = width.isFinite ? (width - actions.width - _gap).clamp(0.0, double.infinity) : double.infinity;
      final lead = measure(_lead, BoxConstraints(minWidth: leadWidth.isFinite ? leadWidth : 0, maxWidth: leadWidth));
      final height = lead.height > actions.height ? lead.height : actions.height;
      final total = constraints.constrain(Size(width.isFinite ? width : lead.width + _gap + actions.width, height));
      if (!dry) {
        final ltr = _textDirection == TextDirection.ltr;
        (_lead.parentData! as _WrapRowData).offset = Offset(
          ltr ? 0 : total.width - lead.width,
          (height - lead.height) / 2,
        );
        (_actions.parentData! as _WrapRowData).offset = Offset(
          ltr ? total.width - actions.width : 0,
          (height - actions.height) / 2,
        );
      }
      return total;
    }
    final full = BoxConstraints(minWidth: width, maxWidth: width);
    final lead = measure(_lead, full);
    final actions = measure(_actions, full);
    if (!dry) {
      (_lead.parentData! as _WrapRowData).offset = Offset.zero;
      (_actions.parentData! as _WrapRowData).offset = Offset(0, lead.height + _gap);
    }
    return constraints.constrain(Size(width, lead.height + _gap + actions.height));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
}
