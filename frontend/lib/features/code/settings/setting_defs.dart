import 'package:flutter/foundation.dart';

import '../harness/everyai/research_sites.dart' show defaultResearchSites;
import 'code_settings.dart';
import 'script_caps.dart';

/// How a setting is edited.
enum SettingKind {
  /// On or off.
  toggle,

  /// One of [SettingDef.choices].
  choice,

  /// A list of short strings, as chips.
  chips,

  /// A long text with Save and Revert.
  prompt,

  /// A spending cap in dollars.
  money,

  /// Allow and deny rules (their own editor).
  permissions,

  /// Lives in another section (MCP servers, skills): a link there.
  link,

  /// The coding agents the app can drive, with their status and consent.
  harnesses,
}

/// Where a setting's value lives.
enum SettingStore {
  /// A `settings.json` layer file (App Support for Global; the project's
  /// `.everyai/settings.json` or `settings.local.json`).
  file,

  /// The app's Preferences ([StoredCodeSettings]).
  prefs,

  /// The session itself (model, effort, mode) or its budget.
  session,

  /// Nowhere here: see [SettingKind.link].
  none,
}

/// One Code setting the layered editor shows as a row.
@immutable
final class SettingDef {
  const SettingDef({
    required this.key,
    required this.title,
    required this.help,
    required this.scopes,
    required this.kind,
    required this.store,
    this.path = const [],
    this.choices = const [],
    this.fallback,
    this.addable = true,
  });

  /// Also the row's anchor in Settings search.
  final String key;
  final String title;
  final String help;
  final Set<SettingsScope> scopes;
  final SettingKind kind;
  final SettingStore store;

  /// The JSON path in a layer file ([SettingStore.file]).
  final List<String> path;

  /// (label, value) for [SettingKind.choice].
  final List<(String, Object)> choices;

  /// The value when no layer sets it.
  final Object? fallback;

  /// Offered by "+ Add setting" when unset (the prompt, permissions and links always show).
  final bool addable;

  String labelOf(Object? value) => choices.where((c) => c.$2 == value).firstOrNull?.$1 ?? '$value';
}

const _gp = {SettingsScope.global, SettingsScope.project};
const _g = {SettingsScope.global};
const _s = {SettingsScope.session};

/// Every Code setting, in display order.
const settingDefs = <SettingDef>[
  SettingDef(
    key: 'prompt',
    title: 'System prompt',
    help:
        'Added to the end of the agent\'s system prompt in new sessions. Fixed once a session starts, so prompt '
        'caching keeps working.',
    scopes: _gp,
    kind: SettingKind.prompt,
    store: SettingStore.prefs,
    fallback: '',
    addable: false,
  ),
  SettingDef(
    key: 'permissions',
    title: 'Permissions',
    help: 'Commands and edits that run without asking (allow), or never run (deny).',
    scopes: _gp,
    kind: SettingKind.permissions,
    store: SettingStore.file,
    addable: false,
  ),
  SettingDef(
    key: 'instructions',
    title: 'Rules',
    help: 'Short project rules the agent follows ("Run dart format -l 120 on changed files").',
    scopes: _gp,
    kind: SettingKind.chips,
    store: SettingStore.file,
    path: ['instructions'],
    fallback: <String>[],
  ),
  SettingDef(
    key: 'commitStyle',
    title: 'Commit style',
    help: 'How agents write commit messages. Automatic follows the repository\'s recent history.',
    scopes: _gp,
    kind: SettingKind.choice,
    store: SettingStore.file,
    path: ['git', 'commitStyle'],
    choices: [('Automatic', 'auto'), ('Conventional', 'conventional'), ('Plain', 'plain')],
    fallback: 'auto',
  ),
  SettingDef(
    key: 'attribution',
    title: 'Attribution',
    help: 'Let commits and PRs name the agent or the tool (Co-authored-by trailers and the like).',
    scopes: _gp,
    kind: SettingKind.toggle,
    store: SettingStore.file,
    path: ['git', 'attribution'],
    fallback: false,
  ),
  SettingDef(
    key: 'tier',
    title: 'Effort level',
    help: 'How much care new EveryAI sessions take. Max, Ultra and Bug fix are workflows in the agent menu.',
    scopes: _g,
    kind: SettingKind.choice,
    store: SettingStore.prefs,
    choices: [
      ('Ultra efficient', HarnessTier.ultraEfficient),
      ('Efficient', HarnessTier.efficient),
      ('Thorough', HarnessTier.thorough),
    ],
    fallback: HarnessTier.efficient,
  ),
  SettingDef(
    key: 'scripts',
    title: 'Scripts (run_script)',
    help:
        'Programs the agent runs in a sandbox to read and filter in bulk, with a fast decider and a cheap model '
        'for sub-questions. By tier: Efficient gets scripts and decide, Thorough and Max add llmQuery, Ultra lets '
        'it recurse. Claude, GPT and Gemini only unless set here.',
    scopes: _g,
    kind: SettingKind.choice,
    store: SettingStore.prefs,
    choices: [
      ('By tier', ScriptLevel.byTier),
      ('Off', ScriptLevel.off),
      ('Scripts + decide', ScriptLevel.decide),
      ('Scripts + llmQuery', ScriptLevel.query),
      ('Deep', ScriptLevel.deep),
    ],
    fallback: ScriptLevel.byTier,
  ),
  SettingDef(
    key: 'autoCompact',
    title: 'Auto-compact',
    help: 'Share of the context window at which EveryAI sessions compact their history.',
    scopes: _g,
    kind: SettingKind.choice,
    store: SettingStore.prefs,
    choices: [('Off', 0), ('40%', 40), ('50%', 50), ('60%', 60), ('70%', 70), ('80%', 80), ('90%', 90)],
    fallback: StoredCodeSettings.defaultAutoCompactPercent,
  ),
  SettingDef(
    key: 'forks',
    title: 'Isolated forks',
    help: 'Writing forks work in a worktree of their own and merge back when done (off: they share the folder).',
    scopes: _g,
    kind: SettingKind.toggle,
    store: SettingStore.prefs,
    fallback: true,
  ),
  SettingDef(
    key: 'researchSites',
    title: 'Research sites',
    help: 'The only sites Max and Ultra research may read. *.example.com covers subdomains.',
    scopes: _g,
    kind: SettingKind.chips,
    store: SettingStore.prefs,
    fallback: defaultResearchSites,
  ),
  SettingDef(
    key: 'model',
    title: 'Model',
    help: 'The model this session runs on. Changing it switches at the next turn.',
    scopes: _s,
    kind: SettingKind.choice,
    store: SettingStore.session,
    addable: false,
  ),
  SettingDef(
    key: 'effort',
    title: 'Effort',
    help: 'How hard a reasoning model thinks in this session.',
    scopes: _s,
    kind: SettingKind.choice,
    store: SettingStore.session,
    choices: [('Default', ''), ('Low', 'low'), ('Medium', 'medium'), ('High', 'high'), ('Max', 'max')],
    addable: false,
  ),
  SettingDef(
    key: 'mode',
    title: 'Mode',
    help: 'What the agent may do without asking in this session.',
    scopes: _s,
    kind: SettingKind.choice,
    store: SettingStore.session,
    addable: false,
  ),
  SettingDef(
    key: 'budget',
    title: 'Spending cap',
    help: 'The session stops when it has spent this much.',
    scopes: _s,
    kind: SettingKind.money,
    store: SettingStore.session,
  ),
  SettingDef(
    key: 'harnesses',
    title: 'Harnesses',
    help: 'The coding agents a session can run on, and whether each is ready on this computer.',
    scopes: _g,
    kind: SettingKind.harnesses,
    store: SettingStore.none,
    addable: false,
  ),
  SettingDef(
    key: 'mcp',
    title: 'MCP servers',
    help: 'Tool servers sessions can use, global or per project.',
    scopes: _gp,
    kind: SettingKind.link,
    store: SettingStore.none,
    addable: false,
  ),
  SettingDef(
    key: 'skills',
    title: 'Skills',
    help: 'SKILL.md folders the agent loads when a task needs them.',
    scopes: _g,
    kind: SettingKind.link,
    store: SettingStore.none,
    addable: false,
  ),
];

/// The definition called [key].
SettingDef settingDef(String key) => settingDefs.firstWhere((d) => d.key == key);

/// The settings a [scope] layer can hold, in display order.
List<SettingDef> defsFor(SettingsScope scope) => [
  for (final d in settingDefs)
    if (d.scopes.contains(scope)) d,
];

// ---- File layers -----------------------------------------------------------

/// Whether [raw] (a layer file) sets [d].
bool isSetInFile(SettingDef d, Map<String, Object?> raw) {
  Object? node = raw;
  for (final k in d.path) {
    if (node is! Map<String, Object?> || !node.containsKey(k)) return false;
    node = node[k];
  }
  return d.path.isNotEmpty;
}

/// [d]'s value in [raw], typed for its kind; null when unset or malformed.
Object? readFileValue(SettingDef d, Map<String, Object?> raw) {
  if (!isSetInFile(d, raw)) return null;
  Object? node = raw;
  for (final k in d.path) {
    node = (node! as Map<String, Object?>)[k];
  }
  return switch (d.kind) {
    SettingKind.toggle => node is bool ? node : null,
    SettingKind.choice => d.choices.any((c) => c.$2 == node) ? node : null,
    SettingKind.chips => switch (node) {
      final String s when s.trim().isNotEmpty => [s.trim()],
      final List<Object?> l => [
        for (final s in l)
          if (s is String && s.trim().isNotEmpty) s.trim(),
      ],
      _ => null,
    },
    _ => node,
  };
}

/// [raw] with [d] set to [value]; every other key, known or not, kept.
Map<String, Object?> writeFileValue(SettingDef d, Map<String, Object?> raw, Object? value) =>
    _setPath(raw, d.path, value);

/// [raw] without [d]; parents left empty by it go too.
Map<String, Object?> clearFileValue(SettingDef d, Map<String, Object?> raw) => _removePath(raw, d.path);

/// [raw] with the JSON value at [path] set to [value] (copies on the way down).
Map<String, Object?> _setPath(Map<String, Object?> raw, List<String> path, Object? value) {
  final out = {...raw};
  if (path.length == 1) {
    out[path.single] = value;
    return out;
  }
  final child = raw[path.first];
  out[path.first] = _setPath(child is Map<String, Object?> ? child : const {}, path.sublist(1), value);
  return out;
}

Map<String, Object?> _removePath(Map<String, Object?> raw, List<String> path) {
  if (!raw.containsKey(path.first)) return raw;
  final out = {...raw};
  if (path.length == 1) {
    out.remove(path.single);
    return out;
  }
  final child = raw[path.first];
  if (child is! Map<String, Object?>) return raw;
  final next = _removePath(child, path.sublist(1));
  if (next.isEmpty) {
    out.remove(path.first);
  } else {
    out[path.first] = next;
  }
  return out;
}

/// The permission rules in a layer file, as written there.
({List<String> allow, List<String> deny}) fileRules(Map<String, Object?> raw) {
  List<String> list(Object? v) => [
    if (v is List<Object?>)
      for (final s in v)
        if (s is String && s.trim().isNotEmpty) s.trim(),
  ];
  final p = raw['permissions'];
  return p is Map<String, Object?> ? (allow: list(p['allow']), deny: list(p['deny'])) : (allow: [], deny: []);
}

/// [raw] with [rule] added to its allow or deny list (once).
Map<String, Object?> addFileRule(Map<String, Object?> raw, String rule, {required bool allow}) {
  final r = fileRules(raw);
  final list = allow ? r.allow : r.deny;
  if (list.contains(rule)) return raw;
  return _setPath(raw, ['permissions', allow ? 'allow' : 'deny'], [...list, rule]);
}

/// [raw] without [rule] in either list; empty lists and objects go.
Map<String, Object?> removeFileRule(Map<String, Object?> raw, String rule) {
  var out = raw;
  final r = fileRules(raw);
  for (final (name, list) in [('allow', r.allow), ('deny', r.deny)]) {
    if (!list.contains(rule)) continue;
    final next = [...list]..remove(rule);
    out = next.isEmpty ? _removePath(out, ['permissions', name]) : _setPath(out, ['permissions', name], next);
  }
  if (out['permissions'] case final Map<String, Object?> p when p.isEmpty) out = {...out}..remove('permissions');
  return out;
}

// ---- Preferences -----------------------------------------------------------

/// Whether [s] sets [d] for the layer ([projectId] null: Global). A value
/// equal to the default counts as unset.
bool isSetInPrefs(SettingDef d, StoredCodeSettings s, String? projectId) {
  final v = readPrefsValue(d, s, projectId);
  return switch (d.key) {
    'prompt' => (v! as String).isNotEmpty,
    'researchSites' => !listEquals(v! as List<String>, defaultResearchSites),
    _ => v != d.fallback,
  };
}

/// [d]'s value in [s] for the layer.
Object? readPrefsValue(SettingDef d, StoredCodeSettings s, String? projectId) => switch (d.key) {
  'prompt' => s.promptFor(projectId),
  'tier' => s.tier,
  'autoCompact' => s.autoCompactPercent,
  'forks' => s.forksIsolated,
  'scripts' => s.scripts,
  'researchSites' => s.researchSites,
  _ => throw ArgumentError('${d.key} is not kept in Preferences'),
};

/// [s] with [d] set to [value] for the layer.
StoredCodeSettings writePrefsValue(SettingDef d, StoredCodeSettings s, String? projectId, Object? value) =>
    switch (d.key) {
      'prompt' => s.withPrompt(projectId, value as String? ?? ''),
      'tier' => s.withTier(value! as HarnessTier),
      'autoCompact' => s.withAutoCompact(value! as int),
      'forks' => s.withForksIsolated(value! as bool),
      'scripts' => s.withScripts(value! as ScriptLevel),
      'researchSites' => s.withResearchSites([...value! as List<String>]),
      _ => throw ArgumentError('${d.key} is not kept in Preferences'),
    };

/// [s] with [d] back at its default for the layer.
StoredCodeSettings clearPrefsValue(SettingDef d, StoredCodeSettings s, String? projectId) =>
    writePrefsValue(d, s, projectId, d.key == 'prompt' ? '' : d.fallback);

/// The value [d] has for a session in the project: the project layer's when
/// it sets it, else Global's, else the default. Null for settings that add up
/// across layers (rules, permissions) or don't live in files.
Object? inheritedFileValue(SettingDef d, Map<String, Object?> global) => readFileValue(d, global) ?? d.fallback;

// ---- Rule builder ----------------------------------------------------------

/// What a permission rule matches, for the "+ Add rule" steps.
enum RuleTool {
  command('Command', 'A shell command: npm test *, git status'),
  edit('Edit files', 'Files the agent may change: src/**, *.md'),
  read('Read files', 'Files the agent reads: .env*, secrets/**'),
  mcp('MCP tool', 'An MCP tool by name: browser_*, playwright_*');

  const RuleTool(this.label, this.hint);
  final String label;
  final String hint;
}

/// The rule text for [pattern] on [tool], in the syntax of `PermissionRules`;
/// null for an empty pattern.
String? ruleFor(RuleTool tool, String pattern) {
  final p = pattern.trim();
  if (p.isEmpty) return null;
  return switch (tool) {
    RuleTool.command => p,
    RuleTool.edit => 'Edit($p)',
    RuleTool.read => 'Read($p)',
    RuleTool.mcp => 'Mcp($p)',
  };
}
