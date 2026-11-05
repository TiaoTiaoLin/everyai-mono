import 'dart:async';

import 'package:crypto/crypto.dart';

import 'dart:convert';

import '../../../core/security/untrusted.dart';
import '../../skills/domain/hidden_instructions.dart';
import '../slash_command.dart';

/// A prompt saved as a Markdown file: `.everyai/commands/<name>.md` in a
/// project, or the same folder in app support for every project.
///
/// ```
/// ---
/// description: Review the staged changes
/// args: <focus>
/// mode: plan
/// model: anthropic/claude-sonnet-5.5
/// ---
/// Review the staged changes. Focus on $ARGUMENTS.
/// ```
final class CustomCommand {
  const CustomCommand({
    required this.name,
    required this.body,
    this.description = '',
    this.args,
    this.model,
    this.mode,
    this.path,
    this.project,
    this.projectDir,
    this.digest = '',
    this.findings = const [],
  });

  /// The file name without `.md`.
  final String name;
  final String body;
  final String description;

  /// The args hint shown after the name.
  final String? args;

  /// A model id to run with. Read and kept; the composers don't switch models from a command yet.
  final String? model;

  /// A chat mode (`search`) or a Code mode (`plan`, `auto-edit`) set before sending.
  final String? mode;

  /// The file; null for a command built in memory.
  final String? path;

  /// The project name, null for a global command.
  final String? project;

  /// The project's folder, null for a global command. A project command is
  /// only offered in that project's sessions.
  final String? projectDir;

  /// SHA-256 of the file text as read; a project command's trust is bound to it.
  final String digest;

  /// Hidden or suspicious text in the file, for the trust review. [body], [description] and [args] have the hidden
  /// characters removed; [digest] is over the file as it is.
  final List<InstructionFinding> findings;

  bool get isGlobal => project == null;

  /// What trust is filed under: the project folder and the name.
  String get trustKey => '${projectDir ?? ''}::$name';

  static final validName = RegExp(r'^[a-z0-9][a-z0-9_-]{0,47}$');

  /// Parses a file. The frontmatter is optional; unknown keys are ignored.
  static CustomCommand parse(String name, String source, {String? path, String? project, String? projectDir}) {
    final text = source.replaceAll('\r\n', '\n');
    final meta = <String, String>{};
    var body = text;
    final m = RegExp(r'^---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)').firstMatch(text);
    if (m != null) {
      body = text.substring(m.end);
      for (final line in m.group(1)!.split('\n')) {
        final i = line.indexOf(':');
        if (i <= 0 || line.startsWith('#') || line.startsWith(' ')) continue;
        meta[line.substring(0, i).trim().toLowerCase()] = _unquote(line.substring(i + 1).trim());
      }
    }
    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = meta[k];
        if (v != null && v.isNotEmpty) return stripHidden(v);
      }
      return null;
    }

    body = stripHidden(body).trim();
    final usesArgs = _placeholder.hasMatch(body);
    return CustomCommand(
      name: name,
      body: body,
      description: pick(['description']) ?? _firstLine(body),
      args: pick(['args', 'argument-hint', 'arguments']) ?? (usesArgs ? '[arguments]' : null),
      model: pick(['model']),
      mode: pick(['mode']),
      path: path,
      project: project,
      projectDir: projectDir,
      digest: sha256.convert(utf8.encode(source)).toString(),
      findings: scanInstructions(source, file: path == null ? '$name.md' : path.split('/').last),
    );
  }

  /// The file text for this command, frontmatter first.
  String toSource() {
    final head = [
      if (description.isNotEmpty) 'description: ${_quote(description)}',
      if (args != null) 'args: ${_quote(args!)}',
      if (model != null) 'model: ${_quote(model!)}',
      if (mode != null) 'mode: ${_quote(mode!)}',
    ];
    return head.isEmpty ? '$body\n' : '---\n${head.join('\n')}\n---\n$body\n';
  }

  /// The message to send: `$ARGUMENTS` becomes all the arguments and `$1`..`$9` the
  /// whitespace-split ones. Arguments given to a body with no placeholder are appended.
  String expand(String arguments) {
    final args = arguments.trim();
    final words = args.isEmpty ? const <String>[] : args.split(RegExp(r'\s+'));
    final out = body.replaceAllMapped(_placeholder, (m) {
      final token = m.group(0)!;
      if (token == r'$ARGUMENTS') return args;
      final i = int.parse(token.substring(1)) - 1;
      return i < words.length ? words[i] : '';
    });
    if (args.isEmpty || _placeholder.hasMatch(body)) return out.trim();
    return '${out.trim()}\n\n$args';
  }

  /// Resolves [mode] against a surface's names, or null when it doesn't name one.
  /// A project command came with the repository, so it may only make the
  /// agent ask for more (Ask, Plan): it never turns approvals off.
  String? modeFor(SlashScope surface) {
    final raw = mode?.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
    if (raw == null) return null;
    const chat = {'chat', 'search', 'research'};
    const code = {'ask': 'ask', 'autoedit': 'autoEdit', 'plan': 'plan', 'fullauto': 'fullAuto'};
    const projectCode = {'ask': 'ask', 'plan': 'plan'};
    if (surface == SlashScope.chat) return chat.contains(raw) ? raw : null;
    return (isGlobal ? code : projectCode)[raw];
  }

  /// The `/` menu entry. Project commands only show in Code.
  ///
  /// With [review] set the command is locked (a project command not trusted
  /// yet): it shows greyed and running it calls [review] instead.
  SlashCommand toSlash({FutureOr<void> Function(SlashContext context)? review}) => SlashCommand(
    name: name,
    description: review != null
        ? 'Came with the project. Review… to turn it on'
        : description.isEmpty
        ? 'Custom command'
        : description,
    locked: review != null,
    argsHint: args,
    group: SlashGroup.custom,
    scope: isGlobal ? SlashScope.both : SlashScope.code,
    project: projectDir,
    run: (ctx, arguments) {
      if (review != null) return review(ctx);
      final mode = modeFor(ctx.surface);
      if (mode != null) {
        ctx.chat?.setMode(mode);
        ctx.code?.setMode(mode);
      }
      final text = expand(arguments);
      if (text.isNotEmpty) ctx.send(text);
    },
  );

  static final _placeholder = RegExp(r'\$ARGUMENTS|\$[1-9]');

  static String _firstLine(String body) {
    for (final l in body.split('\n')) {
      final t = l.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      if (t.isNotEmpty) return t.length > 80 ? '${t.substring(0, 77)}...' : t;
    }
    return '';
  }

  static String _unquote(String v) {
    if (v.length >= 2 && (v.startsWith('"') && v.endsWith('"') || v.startsWith("'") && v.endsWith("'"))) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  static String _quote(String v) => v.contains(': ') || v.contains('#') || v.startsWith('"') || v.startsWith("'")
      ? '"${v.replaceAll('"', r'\"')}"'
      : v;
}
