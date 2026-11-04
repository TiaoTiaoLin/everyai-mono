import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app/router.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/brand.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/chat_providers.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/domain/message.dart';
import '../../code/code_providers.dart';
import '../../code/domain/code_session.dart';
import '../../code/ui/code_home.dart';
import '../../remote/ui/remote_code.dart' show RemoteSessionList;
import '../../settings/ui/account_menu.dart';

/// Width of the collapsed rail. macOS needs room for the traffic lights above it.
double sidebarRailWidth(DesignLanguage design) => Host.hasTrafficLights ? 92 : 60;

/// The app sidebar, Claude-desktop style. Expanded: destinations, then recent
/// chats, then the account. Collapsed: an icon rail with the same destinations.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({
    super.key,
    required this.location,
    required this.collapsed,
    required this.onNavigate,
    required this.onToggle,
  });

  final String location;
  final bool collapsed;
  final ValueChanged<String> onNavigate;
  final VoidCallback onToggle;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  bool _searching = false;

  /// The Code sessions query (chats search through [_matches] instead).
  String _codeQuery = '';

  /// Null when the query is empty; otherwise the matching conversation ids.
  Set<String>? _matches;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    if (widget.collapsed) widget.onToggle();
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  @override
  void didUpdateWidget(Sidebar old) {
    super.didUpdateWidget(old);
    // A query belongs to the space it was typed in.
    if (old.location.startsWith(Routes.code) != widget.location.startsWith(Routes.code) && _searching) _closeSearch();
  }

  void _closeSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _searching = false;
      _matches = null;
      _codeQuery = '';
    });
  }

  void _onQuery(String query) {
    if (widget.location.startsWith(Routes.code)) {
      setState(() => _codeQuery = query);
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      if (query.trim().isEmpty) {
        if (mounted) setState(() => _matches = null);
        return;
      }
      final ids = await ref.read(chatRepositoryProvider).search(query);
      final lower = query.toLowerCase();
      final all = ref.read(conversationsProvider).value ?? const [];
      if (!mounted) return;
      setState(
        () => _matches = {
          ...ids,
          for (final c in all)
            if (c.title.toLowerCase().contains(lower)) c.id,
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final macos = theme.design == DesignLanguage.macos;
    // The title-bar row is shared with the traffic lights on any macOS window.
    final lights = Host.hasTrafficLights;
    final collapsed = widget.collapsed;
    final loc = widget.location;

    final codeMode = loc.startsWith(Routes.code);
    final destinations = codeMode
        ? <_Destination>[
            // Sessions start on the computer; other devices list them.
            if (Host.isDesktop)
              _Destination(EveryIcon.add, 'New session', loc == Routes.code, Routes.code, accent: true)
            else
              _Destination(EveryIcon.projects, 'Sessions', loc == Routes.code, Routes.code),
            if (Host.isDesktop) ...[
              _Destination(
                EveryIcon.search,
                'Search',
                _searching,
                null,
                onTap: _searching ? _closeSearch : _openSearch,
                glyph: 'search',
              ),
              // The project picker lives on the Code home page.
              _Destination(EveryIcon.projects, 'Projects', false, Routes.code, glyph: 'projects'),
            ],
            if (collapsed) _Destination(EveryIcon.chat, 'Chat', false, Routes.newChat, glyph: 'chat'),
            _Destination(EveryIcon.models, 'Models', loc == Routes.models, Routes.models, glyph: 'models'),
          ]
        : <_Destination>[
            _Destination(
              EveryIcon.newChat,
              'New chat',
              loc.startsWith('/chat/') && _isBlankChat(loc),
              Routes.newChat,
              accent: true,
            ),
            _Destination(
              EveryIcon.search,
              'Search',
              _searching,
              null,
              onTap: _searching ? _closeSearch : _openSearch,
              glyph: 'search',
            ),
            _Destination(EveryIcon.chat, 'Chats', loc == Routes.chats, Routes.chats, glyph: 'chat'),
            _Destination(EveryIcon.projects, 'Projects', loc == Routes.projects, Routes.projects, glyph: 'projects'),
            _Destination(
              EveryIcon.artifacts,
              'Artifacts',
              loc == Routes.artifacts,
              Routes.artifacts,
              glyph: 'artifacts',
            ),
            if (collapsed) _Destination(EveryIcon.code, 'Code', false, Routes.code, glyph: 'code'),
            _Destination(EveryIcon.models, 'Models', loc == Routes.models, Routes.models, glyph: 'models'),
          ];

    final header = SizedBox(
      // macOS: the title-bar row, clear of the traffic lights.
      height: lights ? 52 : 56,
      child: collapsed
          ? (lights ? null : Center(child: _toggleButton()))
          : Padding(
              padding: EdgeInsets.only(left: lights ? 92 : 16, right: 8),
              child: Row(
                children: [
                  // The lockup: mark plus the outlined wordmark (never typeset live).
                  Expanded(
                    child: Semantics(
                      label: 'EveryAI',
                      child: Row(
                        children: [
                          BrandMark(size: macos ? 18 : 22),
                          const SizedBox(width: 8),
                          SvgPicture.asset(
                            theme.isDark
                                ? 'assets/brand/logo/wordmark-white.svg'
                                : 'assets/brand/logo/wordmark-ink.svg',
                            height: macos ? 13 : 16,
                            excludeFromSemantics: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                  _toggleButton(),
                ],
              ),
            ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (collapsed && lights) Center(child: _toggleButton()),
        // Code runs on desktop hosts; other devices follow a paired one's
        // sessions (and offer pairing until there is one).
        if (!collapsed)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: _SpaceSwitch(
              code: codeMode,
              onChanged: (code) => widget.onNavigate(code ? Routes.code : Routes.newChat),
            ),
          ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 8, vertical: 2),
          child: Column(
            crossAxisAlignment: collapsed ? CrossAxisAlignment.center : CrossAxisAlignment.stretch,
            children: [
              for (final d in destinations)
                _NavItem(
                  icon: d.icon,
                  label: d.label,
                  selected: d.selected,
                  accent: d.accent,
                  glyph: d.glyph,
                  collapsed: collapsed,
                  onTap: d.onTap ?? () => widget.onNavigate(d.route!),
                ),
            ],
          ),
        ),
        if (!collapsed && _searching && (!codeMode || Host.isDesktop))
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeSearch},
              child: AdaptiveTextField(
                controller: _search,
                focusNode: _searchFocus,
                placeholder: codeMode ? 'Search sessions' : 'Search chats',
                prefix: AdaptiveIcon(EveryIcon.search, size: 15, color: theme.textMuted),
                onChanged: _onQuery,
                textInputAction: TextInputAction.search,
              ),
            ),
          ),
        Expanded(
          child: collapsed
              ? const SizedBox.shrink()
              : codeMode
              ? CodeSessionList(location: loc, query: _codeQuery, onNavigate: widget.onNavigate)
              : _Recents(location: loc, matches: _matches, onNavigate: widget.onNavigate),
        ),
        Container(height: 1, color: theme.border),
        AccountRow(collapsed: collapsed),
      ],
    );
  }

  Widget _toggleButton() => AdaptiveIconButton(
    icon: EveryIcon.sidebar,
    tooltip: widget.collapsed ? 'Expand sidebar' : 'Collapse sidebar',
    onPressed: widget.onToggle,
  );

  /// The current chat is "new" when it has no stored conversation yet.
  bool _isBlankChat(String location) {
    final id = location.substring('/chat/'.length);
    final all = ref.watch(conversationsProvider).value;
    return all != null && !all.any((c) => c.id == id);
  }
}

/// Chat | Code.
class _SpaceSwitch extends StatelessWidget {
  const _SpaceSwitch({required this.code, required this.onChanged});

  final bool code;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget segment(String label, String glyph, bool selected, bool value) => Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: selected ? null : () => onChanged(value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(
                color: selected ? theme.surfaceRaised : null,
                borderRadius: BorderRadius.circular(7),
                boxShadow: [
                  if (selected) const BoxShadow(color: Color(0x1A000000), blurRadius: 3, offset: Offset(0, 1)),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  BrandGlyph(glyph, active: selected, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: (selected ? theme.type.callout.semibold : theme.type.callout.medium).tint(
                      selected ? theme.text : theme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: theme.text.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(9)),
      child: Row(children: [segment('Chat', 'chat', !code, false), segment('Code', 'code', code, true)]),
    );
  }
}

/// [sessions] that match [query] (title, branch or project name; case-insensitive); all when it is blank.
List<CodeSessionInfo> filterSessions(
  List<CodeSessionInfo> sessions,
  String query, {
  Map<String, String> projectNames = const {},
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return sessions;
  bool has(String text) => text.toLowerCase().contains(q);
  return [
    for (final s in sessions)
      if (has(s.title) || has(s.branch) || has(projectNames[s.projectId] ?? '')) s,
  ];
}

/// The sidebar's Code lists: pinned sessions (newest first), then the rest in stored order. Subagents open from
/// their parent's transcript, so they are in neither.
({List<CodeSessionInfo> pinned, List<CodeSessionInfo> recent}) groupCodeSessions(List<CodeSessionInfo> sessions) {
  final own = [
    for (final s in sessions)
      if (!s.isSubagent) s,
  ];
  return (
    pinned: [
      for (final s in own)
        if (s.pinned) s,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    recent: [
      for (final s in own)
        if (!s.pinned) s,
    ],
  );
}

/// Code mode: pinned sessions, then projects, each with its sessions (public for tests).
class CodeSessionList extends ConsumerWidget {
  const CodeSessionList({super.key, required this.location, required this.query, required this.onNavigate});

  final String location;
  final String query;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Host.isDesktop) return RemoteSessionList(location: location, onNavigate: onNavigate, dense: true);
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    final names = {for (final p in projects) p.id: p.name};
    final groups = groupCodeSessions(filterSessions(ref.watch(codeSessionsProvider), query, projectNames: names));
    final searching = query.trim().isNotEmpty;
    final active = location.startsWith('/code/s/') ? location.substring('/code/s/'.length) : null;
    if (projects.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('Open a project to start a session.', style: theme.type.callout.tint(theme.textMuted)),
      );
    }
    if (searching && groups.pinned.isEmpty && groups.recent.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('No matching sessions.', style: theme.type.callout.tint(theme.textMuted)),
      );
    }
    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(text, style: theme.type.caption.semibold.tint(theme.textMuted)),
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (groups.pinned.isNotEmpty) ...[
          label('Pinned'),
          for (final s in groups.pinned)
            SessionTile(
              info: s,
              dense: true,
              selected: s.id == active,
              caption: names[s.projectId],
              onOpen: () => onNavigate(Routes.codeSession(s.id)),
            ),
          if (groups.recent.isNotEmpty) label('Recents'),
        ],
        for (final p in projects)
          if (!searching || groups.recent.any((s) => s.projectId == p.id)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  AdaptiveIcon(EveryIcon.projects, size: 13, color: theme.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      p.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.caption.semibold.tint(theme.textMuted),
                    ),
                  ),
                ],
              ),
            ),
            for (final s in groups.recent.where((s) => s.projectId == p.id))
              SessionTile(
                info: s,
                dense: true,
                selected: s.id == active,
                onOpen: () => onNavigate(Routes.codeSession(s.id)),
              ),
          ],
      ],
    );
  }
}

final class _Destination {
  const _Destination(this.icon, this.label, this.selected, this.route, {this.onTap, this.accent = false, this.glyph});

  final EveryIcon icon;
  final String label;
  final bool selected;
  final String? route;
  final VoidCallback? onTap;
  final bool accent;

  /// A brand feature glyph, drawn instead of [icon].
  final String? glyph;
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    this.accent = false,
    this.glyph,
  });

  final EveryIcon icon;
  final String? glyph;
  final String label;
  final bool selected;
  final bool collapsed;
  final bool accent;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fill = widget.selected
        ? theme.text.withValues(alpha: 0.09)
        : _hover
        ? theme.text.withValues(alpha: 0.05)
        : null;
    final icon = widget.accent
        ? Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(color: theme.primary, shape: BoxShape.circle),
            child: Center(child: AdaptiveIcon(EveryIcon.add, size: 15, color: theme.onPrimary)),
          )
        : SizedBox(
            width: 24,
            child: Center(
              child: widget.glyph != null
                  ? BrandGlyph(widget.glyph!, active: widget.selected, size: 20)
                  : AdaptiveIcon(widget.icon, size: 18, color: theme.text.withValues(alpha: 0.85)),
            ),
          );
    final content = widget.collapsed
        ? SizedBox(width: 40, height: 36, child: Center(child: icon))
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                icon,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: (widget.accent || widget.selected ? theme.type.body.medium : theme.type.body).tint(
                      widget.accent ? theme.accent : theme.text,
                    ),
                  ),
                ),
              ],
            ),
          );
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class _Recents extends ConsumerWidget {
  const _Recents({required this.location, required this.matches, required this.onNavigate});

  final String location;
  final Set<String>? matches;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final conversations = ref.watch(conversationsProvider);
    final activeId = location.startsWith('/chat/') ? location.substring(6) : null;
    final all = conversations.value ?? const <Conversation>[];
    final visible = matches == null ? all : all.where((c) => matches!.contains(c.id)).toList();
    final pinned = visible.where((c) => c.pinned).toList();
    final recent = visible.where((c) => !c.pinned).toList();

    if (conversations.isLoading && all.isEmpty) return const Center(child: AdaptiveProgress());
    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          matches != null ? 'No chats match.' : 'Your chats will appear here.',
          style: theme.type.callout.tint(theme.textMuted),
        ),
      );
    }

    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(text, style: theme.type.caption.semibold.tint(theme.textMuted)),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (pinned.isNotEmpty) ...[
          label('Starred'),
          for (final c in pinned)
            ConversationTile(conversation: c, selected: c.id == activeId, onOpen: () => onNavigate(Routes.chat(c.id))),
        ],
        if (recent.isNotEmpty) ...[
          label(matches == null ? 'Recents' : 'Results'),
          for (final c in recent)
            ConversationTile(conversation: c, selected: c.id == activeId, onOpen: () => onNavigate(Routes.chat(c.id))),
        ],
      ],
    );
  }
}

/// One chat in a list, with a hover menu (star, rename, delete).
class ConversationTile extends ConsumerStatefulWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.selected,
    required this.onOpen,
    this.subtitle,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onOpen;
  final String? subtitle;

  @override
  ConsumerState<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends ConsumerState<ConversationTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final c = widget.conversation;
    final repo = ref.read(chatRepositoryProvider);
    final showMenu = _hover || widget.selected || Host.isMobile;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: Semantics(
          button: true,
          selected: widget.selected,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
            constraints: const BoxConstraints(minHeight: 34),
            decoration: BoxDecoration(
              color: widget.selected
                  ? theme.text.withValues(alpha: 0.09)
                  : _hover
                  ? theme.text.withValues(alpha: 0.05)
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.callout.tint(theme.text),
                      ),
                      if (widget.subtitle != null)
                        Text(widget.subtitle!, style: theme.type.caption.tint(theme.textMuted)),
                    ],
                  ),
                ),
                Opacity(
                  opacity: showMenu ? 1 : 0,
                  child: AdaptiveMenuButton(
                    tooltip: 'Chat options',
                    actions: [
                      MenuAction(
                        label: c.pinned ? 'Unstar' : 'Star',
                        icon: EveryIcon.pin,
                        onSelected: () => repo.setPinned(c.id, pinned: !c.pinned),
                      ),
                      MenuAction(label: 'Rename', icon: EveryIcon.edit, onSelected: () => _rename(repo)),
                      MenuAction(
                        label: 'Delete',
                        icon: EveryIcon.delete,
                        destructive: true,
                        onSelected: () => _confirmDelete(repo),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: AdaptiveIcon(EveryIcon.more, size: 14, color: theme.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _rename(ChatRepository repo) async {
    final title = await showAdaptivePrompt(
      context,
      title: 'Rename chat',
      initialValue: widget.conversation.title,
      confirmLabel: 'Rename',
    );
    if (title != null && title.trim().isNotEmpty) await repo.rename(widget.conversation.id, title.trim());
  }

  Future<void> _confirmDelete(ChatRepository repo) async {
    final confirmed = await showAdaptiveConfirm(
      context,
      title: 'Delete chat?',
      message: '"${widget.conversation.title}" will be permanently deleted from this device.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed) await repo.delete(widget.conversation.id);
  }
}
