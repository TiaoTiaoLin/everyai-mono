import 'agent_prompt.dart';
import 'agent_settings.dart';
import 'settings_stub.dart' if (dart.library.io) 'settings_io.dart' as impl;

export 'agent_settings.dart';
export 'agent_prompt.dart' show HarnessMode, HarnessTier, bugFixRules, tierChangeNote;

/// Project settings committed with the repo.
const projectSettingsPath = '.everyai/settings.json';

/// Personal overrides for one checkout; kept out of git.
const localSettingsPath = '.everyai/settings.local.json';

/// Where the user's own `settings.json` (the Global layer) lives; null where
/// there is no app (headless tools, the web).
Future<String?> userSettingsPath() => impl.userSettingsPath();

/// The `settings.json` layer file for [projectDir]: the committed one, or with
/// [local] the personal, git-excluded `settings.local.json`.
String projectLayerPath(String projectDir, {bool local = false}) =>
    '$projectDir/${local ? localSettingsPath : projectSettingsPath}';

/// The JSON object in the layer file at [path]: empty when the file is
/// missing. Throws [FormatException] when it isn't a JSON object, so an edit
/// never overwrites a file the user broke by hand.
Future<Map<String, Object?>> readLayer(String path) => impl.readLayer(path);

/// Reads the layer file at [path], applies [edit] and writes the result back
/// atomically (a temporary file, then a rename), pretty-printed with two
/// spaces. Keys [edit] doesn't touch, known or not, stay as they were.
Future<Map<String, Object?>> writeLayer(
  String path,
  Map<String, Object?> Function(Map<String, Object?> current) edit,
) => impl.writeLayer(path, edit);

/// The user's settings (App Support `settings.json`), then [projectDir]'s
/// project and local files, merged. Missing or malformed files are skipped.
Future<AgentSettings> loadAgentSettings(String projectDir) => impl.loadAgentSettings(projectDir);

/// [style], or for [CommitStyle.auto] the style of [projectDir]'s recent commits.
Future<CommitStyle> resolveCommitStyle(String projectDir, CommitStyle style) =>
    impl.resolveCommitStyle(projectDir, style);

/// Adds [patterns] to the repository's `info/exclude` (shared by its
/// worktrees). A pattern starting with `/` is relative to [workingDir], which
/// may be a subfolder of the repository. Does nothing outside a git repository.
Future<void> excludeFromGit(String workingDir, List<String> patterns) => impl.excludeFromGit(workingDir, patterns);

/// The persona and system-prompt suffix for a session in [projectDir], from
/// its settings and commit history; [agents] as in [agentPromptSuffix].
/// [isolated] as in [agentPersona].
Future<({String persona, String suffix})> agentPromptFor(
  String projectDir, {
  List<({String name, String description})> agents = const [],
  bool isolated = false,
  HarnessTier tier = HarnessTier.efficient,
  bool forks = false,
  Map<String, String> models = const {},
  HarnessMode harnessMode = HarnessMode.build,
}) async {
  final settings = await loadAgentSettings(projectDir);
  final style = await resolveCommitStyle(projectDir, settings.commitStyle);
  return (
    persona: agentPersona(style: style, attribution: settings.attribution, isolated: isolated),
    suffix: agentPromptSuffix(
      settings,
      agents: agents,
      tier: tier,
      forks: forks,
      models: models,
      harnessMode: harnessMode,
    ),
  );
}
