import 'package:flutter/foundation.dart';

import '../../models/domain/model_catalog.dart';
import '../agent_models.dart';
import 'session_commands.dart';

/// One model in the agent menu: its curated tiers are hints, not the list.
@immutable
final class AgentMenuModel {
  const AgentMenuModel({
    required this.model,
    required this.name,
    required this.vendor,
    this.tiers = const [],
    this.efforts = const [],
  });

  final String model;
  final String name;
  final ModelProvider vendor;

  /// Tier names the catalog places this model in, in tier order ("Engineer").
  final List<String> tiers;

  /// Efforts the catalog lists this model at, recommended first.
  final List<String> efforts;

  String? get recommendedEffort => efforts.firstOrNull;

  /// "Engineer · Orchestrator", or '' when it isn't curated.
  String get tierHint => tiers.join(' · ');
}

/// The vendors and their models for the menu, in catalog order. [current] is
/// added under its vendor when the catalog doesn't list it (a `/model` pick).
List<(ModelProvider, List<AgentMenuModel>)> agentMenuGroups(
  AgentCatalog catalog, {
  String? current,
  String? Function(String model)? nameOf,
}) {
  final tierOrder = {for (final (i, t) in catalog.tiers.indexed) t.id: i};
  final tierName = {for (final t in catalog.tiers) t.id: t.name};
  final byModel = <String, List<AgentChoice>>{};
  for (final c in catalog.models) {
    byModel.putIfAbsent(c.model, () => []).add(c);
  }
  final models = [
    for (final MapEntry(key: model, value: choices) in byModel.entries)
      AgentMenuModel(
        model: model,
        name: choiceModelName(choices.first),
        vendor: ModelProvider.ofModel(ModelId(model)),
        tiers: ([
          ...{for (final c in choices) c.tier},
        ]..sort((a, b) => (tierOrder[a] ?? 99).compareTo(tierOrder[b] ?? 99))).map((t) => tierName[t] ?? t).toList(),
        efforts: [
          ...{for (final c in choices) c.effort},
        ],
      ),
    if (current != null && current.isNotEmpty && !byModel.containsKey(current))
      AgentMenuModel(
        model: current,
        name: nameOf?.call(current) ?? current.split('/').last,
        vendor: ModelProvider.ofModel(ModelId(current)),
      ),
  ];
  final groups = <ModelProvider, List<AgentMenuModel>>{};
  for (final m in models) {
    groups.putIfAbsent(m.vendor, () => []).add(m);
  }
  return [for (final MapEntry(:key, :value) in groups.entries) (key, value)];
}

/// The user's own models ("My models", as in Chat) that can call tools, by
/// vendor in list order; the curated catalog only adds its tiers and tested
/// efforts as hints. [current] is added when the list lacks it.
List<(ModelProvider, List<AgentMenuModel>)> libraryMenuGroups(
  List<ModelSpec> library,
  AgentCatalog catalog, {
  String? current,
  String? Function(String model)? nameOf,
}) {
  final hints = {
    for (final (_, ms) in agentMenuGroups(catalog))
      for (final m in ms) m.model: m,
  };
  final models = [
    for (final s in library)
      if (s.tools)
        AgentMenuModel(
          model: s.id.value,
          name: s.name,
          vendor: ModelProvider.ofModel(s.id),
          tiers: hints[s.id.value]?.tiers ?? const [],
          efforts: hints[s.id.value]?.efforts ?? const [],
        ),
  ];
  if (current != null && current.isNotEmpty && !models.any((m) => m.model == current)) {
    models.add(
      AgentMenuModel(
        model: current,
        name: nameOf?.call(current) ?? current.split('/').last,
        vendor: ModelProvider.ofModel(ModelId(current)),
      ),
    );
  }
  final groups = <ModelProvider, List<AgentMenuModel>>{};
  for (final m in models) {
    groups.putIfAbsent(m.vendor, () => []).add(m);
  }
  return [for (final MapEntry(:key, :value) in groups.entries) (key, value)];
}

/// "Opus 5.5" from "Opus 5.5 · medium".
String choiceModelName(AgentChoice c) {
  final dot = c.label.indexOf(' · ');
  return dot == -1 ? c.label : c.label.substring(0, dot);
}

/// The effort to use after switching to [model]: keep [current] when the
/// catalog lists the model at it (or doesn't know the model), otherwise
/// take the model's recommended effort.
String effortForModel(AgentMenuModel model, String current) {
  if (model.efforts.isEmpty || model.efforts.contains(current)) return current;
  return model.recommendedEffort ?? current;
}

/// The effort rows: the model's default, then every level.
const agentMenuEfforts = ['', ...codeEfforts];

String effortLabel(String effort) => switch (effort) {
  '' => 'Default',
  'low' => 'Low',
  'medium' => 'Medium',
  'high' => 'High',
  'xhigh' => 'Extra high',
  'max' => 'Max',
  _ => effort,
};

String effortBlurb(String effort) => switch (effort) {
  '' => "The model's own setting",
  'low' => 'Quickest, thinks least',
  'medium' => 'Balanced',
  'high' => 'Thinks harder on each step',
  'xhigh' => 'For hard problems',
  'max' => 'Thinks the most; slowest and costliest',
  _ => '',
};

/// The trigger text: "Opus 5.5 · High", or just the name at the default.
String agentMenuLabel(String name, String effort) => effort.isEmpty ? name : '$name · ${effortLabel(effort)}';
