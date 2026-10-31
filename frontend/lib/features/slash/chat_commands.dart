import '../../core/ui/adaptive.dart';
import '../chat/domain/message.dart';
import '../chat/domain/reasoning_effort.dart';
import 'slash_command.dart';

/// Make-commands and the tool each one forces on the model's first call.
const forcedTools = <String, ({String tool, String hint, String description})>{
  'slides': (tool: 'make_slides', hint: '<topic>', description: 'Make a slide deck'),
  'quiz': (tool: 'make_quiz', hint: '<topic>', description: 'Make an interactive quiz'),
  'flashcards': (tool: 'make_flashcards', hint: '<topic>', description: 'Make a deck of flip cards'),
  'diagram': (tool: 'render_diagram', hint: '<what to draw>', description: 'Draw a Mermaid diagram'),
  'svg': (tool: 'render_svg', hint: '<what to draw>', description: 'Draw an SVG illustration'),
  'image': (tool: 'generate_image', hint: '<what to generate>', description: 'Generate an image'),
  'doc': (tool: 'create_artifact', hint: '<what to write>', description: 'Write a document in the side panel'),
};

/// The effort named by [text] (`low`, `High`, `default`), or null.
ReasoningEffort? parseEffortArg(String text) {
  final t = text.trim().toLowerCase();
  if (t == 'default' || t == 'none') return ReasoningEffort.auto;
  for (final e in ReasoningEffort.values) {
    if (e.name == t) return e;
  }
  return null;
}

/// What a loaded skill adds to the model's view of the next message. It sits
/// in the user turn, not the system prompt, so the cached prefix is untouched.
String skillContext(String name, String body) =>
    '<skill name="$name">\n${body.trim()}\n</skill>\n\nUse the skill above for this request.';

/// A chat as Markdown for saving: a title, then each turn under a heading.
String chatToMarkdown(String title, List<Message> messages) {
  final out = StringBuffer('# ${title.trim().isEmpty ? 'Chat' : title.trim()}\n');
  for (final m in messages) {
    if (m.role == Role.system) continue;
    if (m.status != MessageStatus.complete && m.plainText.trim().isEmpty) continue;
    out.write('\n## ${m.isUser ? 'You' : 'Assistant'}\n\n');
    for (final part in m.parts) {
      switch (part) {
        case TextPart(:final text) when text.trim().isNotEmpty:
          out.write('${text.trim()}\n\n');
        case AttachmentPart(:final name):
          out.write('_Attached: ${name}_\n\n');
        case ToolCallPart(:final toolName):
          out.write('_${_toolNote(toolName)}_\n\n');
        case ImagePart():
          out.write('_Generated an image_\n\n');
        default:
          break;
      }
    }
  }
  return '${out.toString().trimRight()}\n';
}

String _toolNote(String tool) => switch (tool) {
  'make_slides' => 'Made a slide deck',
  'make_quiz' => 'Made a quiz',
  'make_flashcards' => 'Made flashcards',
  'render_diagram' => 'Drew a diagram',
  'render_svg' => 'Drew an illustration',
  'render_chart' => 'Drew a chart',
  'create_artifact' || 'update_artifact' || 'edit_artifact' => 'Wrote a document in the side panel',
  _ => 'Used $tool',
};

/// Switches to a mode (named [mode] when the command's [name] differs).
SlashCommand _chatMode(String name, String description, {String? mode}) => SlashCommand(
  name: name,
  description: description,
  argsHint: '[message]',
  scope: SlashScope.chat,
  run: (ctx, args) {
    ctx.chat?.setMode(mode ?? name);
    if (args.isNotEmpty) ctx.send(args);
  },
);

SlashCommand _make(String name) {
  final f = forcedTools[name]!;
  return SlashCommand(
    name: name,
    description: f.description,
    argsHint: f.hint,
    scope: SlashScope.chat,
    run: (ctx, args) {
      final send = ctx.chat?.sendWith;
      if (send == null) return;
      if (args.isEmpty) {
        showAdaptiveToast(ctx.context, 'Add what to make: /$name ${f.hint}');
        return;
      }
      send(args, forceTool: f.tool);
    },
  );
}

void _tell(SlashContext ctx, String? message) {
  if (message != null && message.isNotEmpty) showAdaptiveToast(ctx.context, message);
}

/// The chat composer's built-in commands.
final chatBuiltIns = <SlashCommand>[
  _chatMode('chat', 'Answer from the model alone'),
  _chatMode('search', 'Search the web and cite sources'),
  _chatMode('research', 'Multi-step research with a report'),
  // /learn makes a skill from the chat, so Learn mode is /teach.
  _chatMode('teach', 'Learn mode: step-by-step teaching with visuals and quizzes', mode: 'learn'),
  _chatMode('summarise', 'Condense a file, page or chat'),
  SlashCommand(
    name: 'model',
    description: 'Switch the model',
    argsHint: '[name]',
    scope: SlashScope.chat,
    run: (ctx, args) {
      if (args.isEmpty) {
        final open = ctx.chat?.openModelPicker;
        return open != null ? open() : showAdaptiveToast(ctx.context, 'Name a model: /model sonnet');
      }
      _tell(ctx, ctx.chat?.setModel?.call(args));
    },
  ),
  SlashCommand(
    name: 'effort',
    description: 'Set how hard the model thinks',
    argsHint: '<auto|low|medium|high|max>',
    scope: SlashScope.chat,
    run: (ctx, args) {
      if (args.isEmpty) return showAdaptiveToast(ctx.context, 'Pick one: auto, low, medium, high or max');
      _tell(ctx, ctx.chat?.setEffort?.call(args));
    },
  ),
  SlashCommand(
    name: 'new',
    description: 'Start a new chat',
    scope: SlashScope.chat,
    run: (ctx, _) => ctx.chat?.newChat?.call(),
  ),
  SlashCommand(
    name: 'retry',
    description: 'Answer the last message again',
    scope: SlashScope.chat,
    run: (ctx, _) => ctx.chat?.retry?.call(),
  ),
  for (final name in forcedTools.keys) _make(name),
  SlashCommand(
    name: 'memory',
    description: 'Open your saved memory',
    scope: SlashScope.chat,
    run: (ctx, _) => ctx.chat?.openMemory?.call(),
  ),
  SlashCommand(
    name: 'connectors',
    description: 'Connect apps and services',
    scope: SlashScope.chat,
    run: (ctx, _) => showAdaptiveToast(ctx.context, 'Connectors are coming later.'),
  ),
  SlashCommand(
    name: 'export',
    description: 'Save this chat as Markdown, PDF or Word',
    argsHint: '[md|pdf|docx]',
    scope: SlashScope.chat,
    run: (ctx, args) => ctx.chat?.exportChat?.call(args),
  ),
  SlashCommand(
    name: 'learn',
    description: 'Turn this chat into a reusable skill',
    argsHint: '[what it is for]',
    scope: SlashScope.chat,
    run: (ctx, args) => ctx.chat?.saveAsSkill?.call(args),
  ),
];

/// A `/<skill-name>` entry for the Skills group. With a request after it the
/// message goes out with the skill loaded; alone, the skill waits for the
/// user's next message. The skills settings step feeds its enabled skills in
/// here through `skillSlashCommandsProvider`.
SlashCommand skillSlashCommand({required String name, required String description, required String body}) =>
    SlashCommand(
      name: name,
      description: description,
      argsHint: '[request]',
      group: SlashGroup.skills,
      scope: SlashScope.chat,
      run: (ctx, args) {
        final context = skillContext(name, body);
        final chat = ctx.chat;
        if (args.isNotEmpty && chat?.sendWith != null) {
          chat!.sendWith!(args, context: context);
        } else if (chat?.stage != null) {
          chat!.stage!(name, context);
          showAdaptiveToast(ctx.context, 'The $name skill will be used for your next message.');
        }
      },
    );
