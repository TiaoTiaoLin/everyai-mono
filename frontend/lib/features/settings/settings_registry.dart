import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/platform_kind.dart';
import '../../core/ui/every_icons.dart';

/// The groups of the Settings section list, in order.
enum SettingsGroup {
  preferences('Preferences'),
  code('Code'),
  computer('This computer'),
  about('');

  const SettingsGroup(this.label);
  final String label;
}

/// A page of the Settings modal.
enum SettingsSection {
  general('General', SettingsGroup.preferences, EveryIcon.general),
  account('Account', SettingsGroup.preferences, EveryIcon.person),
  apiKeys('Add API keys', SettingsGroup.preferences, EveryIcon.key),
  billing('Billing', SettingsGroup.preferences, EveryIcon.card),
  usage('Usage', SettingsGroup.preferences, EveryIcon.usage),
  models('Models', SettingsGroup.preferences, EveryIcon.models),
  memory('Memory', SettingsGroup.preferences, EveryIcon.memory),
  code('Code', SettingsGroup.code, EveryIcon.code, desktopOnly: true),
  permissions('Permissions', SettingsGroup.code, EveryIcon.shield, desktopOnly: true),
  mcp('MCP servers', SettingsGroup.code, EveryIcon.plug, desktopOnly: true),
  skills('Skills', SettingsGroup.code, EveryIcon.skill, desktopOnly: true),
  agents('Agents', SettingsGroup.code, EveryIcon.agents, desktopOnly: true),
  commands('Commands', SettingsGroup.code, EveryIcon.command),
  remote('Remote', SettingsGroup.computer, EveryIcon.devices),
  developer('Developer', SettingsGroup.computer, EveryIcon.wrench),
  about('About', SettingsGroup.about, EveryIcon.info);

  const SettingsSection(this.title, this.group, this.icon, {this.desktopOnly = false});
  final String title;
  final SettingsGroup group;
  final EveryIcon icon;

  /// Shown on desktop hosts only (the Code workspace runs there).
  final bool desktopOnly;

  bool get available => !desktopOnly || Host.isDesktop;

  static SettingsSection? parse(Object? v) => values.where((s) => s.name == v).firstOrNull;
}

/// A row search can find: [anchor] is the id its [SettingsAnchor] carries in
/// the section body (null: the section itself).
@immutable
final class SettingsEntry {
  const SettingsEntry(this.section, this.title, {this.anchor, this.keywords = const []});

  final SettingsSection section;
  final String? anchor;
  final String title;
  final List<String> keywords;

  /// Every word of [query] appears in the title, keywords or section name.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return false;
    final hay = [title, section.title, ...keywords].join(' ').toLowerCase();
    return words.every(hay.contains);
  }
}

/// The search index: one entry per section plus its notable rows.
const settingsEntries = <SettingsEntry>[
  SettingsEntry(SettingsSection.general, 'General', keywords: ['preferences']),
  SettingsEntry(SettingsSection.general, 'Theme', anchor: 'theme', keywords: ['dark', 'light', 'appearance', 'mode']),
  SettingsEntry(SettingsSection.general, 'Design', anchor: 'design', keywords: ['look', 'macos', 'material', 'fluent']),
  SettingsEntry(SettingsSection.general, 'Default model', anchor: 'default-model', keywords: ['chat', 'model']),
  SettingsEntry(
    SettingsSection.general,
    'Reply language',
    anchor: 'language',
    keywords: ['language', 'translate', 'locale', 'follow-ups'],
  ),
  SettingsEntry(SettingsSection.account, 'Account', keywords: ['profile', 'sign in']),
  SettingsEntry(SettingsSection.account, 'Sign out', anchor: 'sign-out', keywords: ['log out', 'logout']),
  SettingsEntry(SettingsSection.apiKeys, 'Add API keys', keywords: ['byok', 'bring your own key', 'provider']),
  SettingsEntry(SettingsSection.apiKeys, 'Anthropic key', anchor: 'anthropic', keywords: ['claude']),
  SettingsEntry(SettingsSection.apiKeys, 'OpenRouter key', anchor: 'openrouter'),
  SettingsEntry(
    SettingsSection.apiKeys,
    'Ultra spend cap',
    anchor: 'ultra-cap',
    keywords: ['budget', 'limit', 'ultra'],
  ),
  SettingsEntry(SettingsSection.billing, 'Billing', keywords: ['plan', 'wallet', 'top up', 'credits', 'payment']),
  SettingsEntry(SettingsSection.billing, 'Plans', anchor: 'plans', keywords: ['plus', 'super', 'upgrade', 'price']),
  SettingsEntry(SettingsSection.billing, 'Wallet and top-ups', anchor: 'wallet', keywords: ['credits', 'top up']),
  SettingsEntry(SettingsSection.usage, 'Usage', keywords: ['spend', 'tokens', 'cost', 'cache']),
  SettingsEntry(SettingsSection.models, 'My models', keywords: ['library', 'shop', 'catalog']),
  SettingsEntry(SettingsSection.memory, 'Memory', keywords: ['notes', 'remember', 'search chats']),
  SettingsEntry(SettingsSection.code, 'Code settings', keywords: ['layers', 'global', 'project', 'session']),
  SettingsEntry(
    SettingsSection.code,
    'System prompt',
    anchor: 'prompt',
    keywords: ['instructions', 'custom instructions', 'prompt'],
  ),
  SettingsEntry(SettingsSection.code, 'Auto-compact', anchor: 'autoCompact', keywords: ['context', 'compaction']),
  SettingsEntry(SettingsSection.code, 'Forks', anchor: 'forks', keywords: ['worktree', 'isolated']),
  SettingsEntry(
    SettingsSection.code,
    'Effort level',
    anchor: 'tier',
    keywords: ['efficient', 'thorough', 'quality', 'tier'],
  ),
  SettingsEntry(SettingsSection.code, 'Research sites', anchor: 'researchSites', keywords: ['web', 'domains']),
  SettingsEntry(SettingsSection.code, 'Commit style', anchor: 'commitStyle', keywords: ['git', 'conventional']),
  SettingsEntry(SettingsSection.code, 'Attribution', anchor: 'attribution', keywords: ['git', 'co-authored']),
  SettingsEntry(SettingsSection.code, 'Spending cap', anchor: 'budget', keywords: ['budget', 'session', 'cost']),
  SettingsEntry(SettingsSection.code, 'View as JSON', anchor: 'json', keywords: ['settings.json', 'raw']),
  SettingsEntry(SettingsSection.permissions, 'Permissions', keywords: ['allow', 'deny', 'rules', 'approve']),
  SettingsEntry(SettingsSection.mcp, 'MCP servers', keywords: ['tools', 'playwright', 'servers']),
  SettingsEntry(SettingsSection.skills, 'Skills', keywords: ['skill.md', 'abilities']),
  SettingsEntry(SettingsSection.agents, 'Agents', keywords: ['subagents', 'reviewer']),
  SettingsEntry(SettingsSection.commands, 'Custom commands', keywords: ['slash', 'prompts', 'commands']),
  SettingsEntry(SettingsSection.remote, 'Remote coding', keywords: ['phone', 'pair', 'devices', 'qr']),
  SettingsEntry(SettingsSection.developer, 'Developer', keywords: ['upstream', 'anthropic', 'debug']),
  SettingsEntry(SettingsSection.about, 'About', keywords: ['version', 'server']),
  SettingsEntry(SettingsSection.about, 'Third-party notices', anchor: 'notices', keywords: ['licenses', 'open source']),
];

/// The entries [query] finds among [available] sections, in index order.
List<SettingsEntry> searchSettings(String query, {bool Function(SettingsSection)? available}) => [
  for (final e in settingsEntries)
    if ((available ?? (s) => s.available)(e.section) && e.matches(query)) e,
];

/// Where the Settings modal should be: a section, a row in it, and arguments
/// for the section (the Code section's scope, project and session). [seq]
/// tells two requests for the same place apart, so each one jumps.
@immutable
final class SettingsTarget {
  const SettingsTarget(this.section, {this.anchor, this.args = const {}, this.seq = 0});

  final SettingsSection section;
  final String? anchor;
  final Map<String, String> args;
  final int seq;

  @override
  String toString() => 'SettingsTarget(${section.name}, $anchor, $args)';
}

/// The place the open modal shows; anchors scroll to themselves when it names them.
final settingsTargetProvider = NotifierProvider<SettingsTargetNotifier, SettingsTarget?>(SettingsTargetNotifier.new);

final class SettingsTargetNotifier extends Notifier<SettingsTarget?> {
  int _seq = 0;

  @override
  SettingsTarget? build() => null;

  void go(SettingsSection section, {String? anchor, Map<String, String> args = const {}}) =>
      state = SettingsTarget(section, anchor: anchor, args: args, seq: ++_seq);

  /// Called by the anchor once it has scrolled into view: a rebuilt anchor
  /// won't jump again.
  void reached(int seq) {
    if (state?.seq == seq && state?.anchor != null) {
      final s = state!;
      state = SettingsTarget(s.section, args: s.args, seq: s.seq);
    }
  }
}

/// A request to open Settings from somewhere without a [BuildContext] for it
/// (an old `/settings/...` link); the app shell opens the modal.
final pendingSettingsProvider = NotifierProvider<PendingSettings, SettingsTarget?>(PendingSettings.new);

final class PendingSettings extends Notifier<SettingsTarget?> {
  @override
  SettingsTarget? build() => null;

  void request(SettingsTarget target) => state = target;

  SettingsTarget? take() {
    final t = state;
    state = null;
    return t;
  }
}

/// Whether the Settings modal is showing (a second open only jumps).
final settingsOpenProvider = NotifierProvider<SettingsOpen, bool>(SettingsOpen.new);

final class SettingsOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool open) => state = open;
}

/// The Settings place an old route stands for: `/settings`, `/settings/<x>`
/// and `/code/settings?scope&project&session&tab`; null for anything else.
SettingsTarget? settingsTargetForLocation(Uri uri) {
  final path = uri.path.endsWith('/') && uri.path.length > 1 ? uri.path.substring(0, uri.path.length - 1) : uri.path;
  if (path == '/code/settings') {
    final q = uri.queryParameters;
    final tab = q['tab'];
    return SettingsTarget(
      SettingsSection.code,
      anchor: tab == 'prompt' ? 'prompt' : (tab == 'json' || tab == 'effective' ? 'json' : null),
      args: {'scope': ?q['scope'], 'project': ?q['project'], 'session': ?q['session']},
    );
  }
  if (path == '/settings') return const SettingsTarget(SettingsSection.general);
  if (!path.startsWith('/settings/')) return null;
  final rest = path.substring('/settings/'.length);
  final section = switch (rest) {
    'billing' => SettingsSection.billing,
    'usage' => SettingsSection.usage,
    'memory' => SettingsSection.memory,
    'commands' => SettingsSection.commands,
    'mcp' => SettingsSection.mcp,
    'skills' => SettingsSection.skills,
    'agents' => SettingsSection.agents,
    'remote' => SettingsSection.remote,
    'notices' => SettingsSection.about,
    'keys' || 'api-keys' => SettingsSection.apiKeys,
    _ => SettingsSection.parse(rest) ?? SettingsSection.general,
  };
  return SettingsTarget(section, anchor: rest == 'notices' ? 'notices' : uri.queryParameters['anchor']);
}
