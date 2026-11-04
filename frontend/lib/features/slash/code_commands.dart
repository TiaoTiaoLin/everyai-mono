import '../../core/ui/adaptive.dart';
import 'slash_command.dart';

/// Runs [action] with the args, or says the command needs an open session.
void _withSession<T>(SlashContext ctx, T? action, void Function(T action) run) {
  if (action == null) {
    showAdaptiveToast(ctx.context, 'Open a session first.');
    return;
  }
  run(action);
}

SlashCommand _code(
  String name,
  String description,
  void Function(SlashContext ctx, String args) run, {
  String? argsHint,
}) => SlashCommand(name: name, description: description, argsHint: argsHint, scope: SlashScope.code, run: run);

/// The Code composer's built-in session commands.
final codeBuiltIns = <SlashCommand>[
  _code('plan', 'Switch to Plan mode: read and propose before editing', argsHint: '[what to plan]', (ctx, args) {
    ctx.code?.setMode('plan');
    if (args.isNotEmpty) ctx.send(args);
  }),
  _code('build', 'Leave Plan mode and start building', argsHint: '[instructions]', (ctx, args) {
    final build = ctx.code?.build;
    if (build != null) return build(args);
    ctx.code?.setMode('autoEdit');
    if (args.isNotEmpty) ctx.send(args);
  }),
  _code('model', "Switch the session's model", argsHint: '<name> [effort]', (ctx, args) {
    if (args.isEmpty) return showAdaptiveToast(ctx.context, 'Name a model: /model sonnet');
    _withSession(ctx, ctx.code?.setModel, (f) => f(args));
  }),
  _code('effort', 'Set how hard the model thinks', argsHint: '<low|medium|high|xhigh|max|default>', (ctx, args) {
    if (args.isEmpty) return showAdaptiveToast(ctx.context, 'Pick one: low, medium, high, xhigh, max or default');
    _withSession(ctx, ctx.code?.setEffort, (f) => f(args));
  }),
  _code('clear', 'Start a fresh session in this project', argsHint: '[first message]', (ctx, args) {
    _withSession(ctx, ctx.code?.clear, (f) => f(args));
  }),
  _code('compact', "Summarize older turns to free the agent's context", argsHint: '[what to keep]', (ctx, args) {
    _withSession(ctx, ctx.code?.compact, (f) => f(args));
  }),
  _code('rewind', 'Go back to before the last turn (conversation and files)', argsHint: '[turns]', (ctx, args) {
    _withSession(ctx, ctx.code?.rewind, (f) => f(args));
  }),
  _code('stop', 'Stop the agent', (ctx, _) {
    final stop = ctx.code?.stop;
    if (stop == null) return showAdaptiveToast(ctx.context, 'The agent is not working.');
    stop();
  }),
  _code('cost', 'Show tokens and spend for this session', (ctx, _) {
    _withSession(ctx, ctx.code?.cost, (f) => f());
  }),
  _code('btw', 'Ask a side question without interrupting the agent', argsHint: '<question>', (ctx, args) {
    if (args.isEmpty) return showAdaptiveToast(ctx.context, 'Add a question: /btw what is the agent testing?');
    _withSession(ctx, ctx.code?.btw, (f) => f(args));
  }),
  // No args hint: each of these runs as picked; text after the name is optional.
  _code('review', "Have a reviewer subagent check this session's changes", (ctx, args) {
    _withSession(ctx, ctx.code?.review, (f) => f(args));
  }),
  _code('goal', 'Keep the agent at a goal until a check finds it met', argsHint: '<objective> [--turns N] | clear', (
    ctx,
    args,
  ) {
    _withSession(ctx, ctx.code?.goal, (f) => f(args));
  }),
  _code('commit', 'Commit the changes with a drafted message you can edit', (ctx, args) {
    _withSession(ctx, ctx.code?.commit, (f) => f(args));
  }),
  _code('pr', 'Open a pull request for this session (GitHub CLI)', (ctx, args) {
    _withSession(ctx, ctx.code?.pr, (f) => f(args));
  }),
  _code('learn', 'Turn a folder, a web page or this session into a skill', (ctx, args) {
    _withSession(ctx, ctx.code?.learn, (f) => f(args));
  }),
  _code('morning', "A brief of your sessions: what's waiting on you, running and ready to merge", (ctx, _) {
    final morning = ctx.code?.morning;
    if (morning == null) return showAdaptiveToast(ctx.context, 'The brief is not available here.');
    morning();
  }),
];
