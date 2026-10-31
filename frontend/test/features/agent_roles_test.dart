import 'package:every_ai/features/agents/agents_providers.dart';
import 'package:every_ai/features/agents/domain/agent_definition.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:every_ai/features/code/settings/settings.dart' show AgentSettings;
import 'package:flutter_test/flutter_test.dart';

void main() {
  AgentDefinition role({String? model, String? effort}) => AgentDefinition.parse(
    '---\nname: reviewer\ndescription: Reviews.\n${model == null ? '' : 'model: $model\n'}'
    '${effort == null ? '' : 'effort: $effort\n'}permissions: plan\n---\nReview carefully.\n',
    fileName: 'reviewer.md',
    source: AgentSource.builtin,
  );

  test("the user's preferred model and effort for a role win over its file", () {
    final setup = childSetup(
      role(model: 'openai/gpt-6.1-sol', effort: 'high'),
      parentMode: AgentMode.fullAuto,
      parentModel: 'anthropic/claude-sonnet-5.5',
      parentEffort: 'medium',
      preferred: (model: 'google/gemini-argon', effort: 'low'),
    );
    expect(setup.model, 'google/gemini-argon');
    expect(setup.effort, 'low');
    expect(setup.mode, AgentMode.plan);
  });

  test("a role whose model can't be used falls back to the orchestrator's model and effort", () {
    final setup = childSetup(
      role(),
      parentMode: AgentMode.autoEdit,
      parentModel: 'anthropic/claude-sonnet-5.5',
      parentEffort: 'medium',
      preferred: (model: 'nobody/no-tools', effort: 'max'),
      modelKnown: (m) => m != 'nobody/no-tools',
    );
    expect(setup.model, 'anthropic/claude-sonnet-5.5');
    expect(setup.effort, 'medium');
  });

  test('preferred models are stored per role, and clearing both drops the entry', () {
    var s = const AgentLibrarySettings().withPreferred('researcher', model: 'google/gemini-argon');
    s = AgentLibrarySettings.fromJson(s.toJson());
    expect(s.preferredFor('researcher').model, 'google/gemini-argon');
    expect(s.withPreferred('researcher', model: '').preferred, isEmpty);
    expect(s.withEnabled('x', false).preferredFor('researcher').model, 'google/gemini-argon');
  });

  test('a fork brief carries its role and, for research, the sandbox', () {
    const task = SubagentTask(description: 'Research HTTP servers', prompt: 'Find the best C HTTP servers.');
    final brief = forkBrief(task, role: 'You research.', research: ['github.com']);
    expect(brief, contains('<fork-role>'));
    expect(brief, contains('You are a research job'));
    expect(brief, contains('github.com'));
    expect(forkBrief(task), isNot(contains('<fork-role>')));
  });

  test('the forking task spec takes a role, not an agent', () {
    final props = (forkingTaskSpec()['parameters']! as Map)['properties']! as Map;
    expect(props.containsKey('role'), isTrue);
    expect(props.containsKey('agent'), isFalse);
  });

  test('a forking session is offered other models for its children; others are not', () {
    final models = {'google/gemini-argon': 'Gemini Argon'};
    final suffix = agentPromptSuffix(AgentSettings.defaults, forks: true, models: models);
    expect(suffix, allOf(contains('<MODELS>'), contains('google/gemini-argon: Gemini Argon')));
    expect(agentPromptSuffix(AgentSettings.defaults, models: models), isNot(contains('<MODELS>')));
    final props = (forkingTaskSpec()['parameters']! as Map)['properties']! as Map;
    expect(props.containsKey('model'), isTrue);
  });
}
