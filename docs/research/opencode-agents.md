# How opencode manages its agents, and what EveryAI should copy

Research date: 2026-10-30. Scope: opencode only. A Claude Code audit comes later.

## Sources and citation format

- **Repository:** `github.com/sst/opencode` now redirects to **`github.com/anomalyco/opencode`**: the GitHub API returns
  `full_name: anomalyco/opencode`, default branch `dev`, license MIT. Two release lines ship in parallel:
  - **[v1]**: tag `v1.19.5` (2026-10-28), the classic TUI. Code lives in `packages/opencode/src/…`.
    Links: `https://github.com/anomalyco/opencode/blob/v1.19.5/<path>`.
  - **[dev]**: branch `dev` at `ab60ee2` (2026-10-30, `package.json` version 2.2.2), the v2 rewrite on Effect. Code
    lives in `packages/core/src/…`. Links: `https://github.com/anomalyco/opencode/blob/ab60ee227bbfed225d22e78187cc5359b8a14cbf/<path>`.
- **Docs:** `https://opencode.ai/docs/<page>`, built from `packages/web/src/content/docs/<page>.mdx`. On 2026-10-30 the live
  agents page matched the **dev** copy ("two built-in subagents, General and Explore"; Plan "Denies file edits…").
  The v1.19.5 copy differs in places, as noted below. The v2 docs site source is `services/www/src/docs/content/` in [dev].
- **Citation format:** `[v1] path:line` or `[dev] path:line`. Line numbers come from shallow clones in
  `/private/tmp/claude-501/opencode-research/{v1,repo}`.
- **Version used:** we don't know which line the user tried (see Open questions). Where v1 and v2 differ, both are given.

---

## 1. Summary: the most valuable things to copy, ranked by impact on agent quality

1. **Recover from output-limit truncation instead of stalling.** This matches our "stuck" symptom exactly.
   - When a response ends with `stop_reason: length` mid tool call, opencode v2 does not execute the call. It fails
     the call with a tool result that says *why*: "The tool call was not executed because the output token limit
     (stop reason: length) was reached before you could complete the arguments. Break large payloads into smaller
     tool calls and reissue the call with complete arguments." It attaches an input excerpt
     ([dev] `packages/core/src/session/runner/publish-llm-event.ts:40-56,664-671`).
   - If the response called no tools, it injects a synthetic "Your last response hit the output token limit… Break
     the remaining work into smaller pieces." It gives up after two consecutive continuations
     ([dev] `session/runner/llm.ts:37-41,336-366`).
   - It also fits `max_tokens` to the room left in the context window ([dev] `session/model-request.ts:47-97`).
   - **For us:** this can be done in our **gateway** (`backend-exp/src/gateway.zig`) without touching OpenHands
     (see §7).
2. **Make Plan mode a re-asserted harness reminder with an explicit "you have left Plan mode" message.**
   - v1 appends the Plan reminder to the latest user message on **every** model call while Plan is active.
   - v2 persists it once and **re-inserts it whenever compaction or a revert removed it**. It inserts a matching
     "You are NO LONGER in Plan mode" message when the user leaves Plan.
   - Both tell the model that the reminder is harness text it must follow.
   - Ours is sent once per mode change and can be lost to OpenHands condensation.
3. **Ask the user inside the tool call, so the agent keeps its turn.**
   - opencode's `question` tool blocks until the user answers, then returns the answers as the tool result: "User
     has answered your questions: "Q"="A". You can now continue with the user's answers in mind."
   - Its `plan_exit` tool asks "switch to build?" through the same UI. On Yes it switches agent itself and queues
     "The plan at X has been approved, you can now edit files. Execute the plan".
   - Our client tools must end the turn, which invites the agent to stop and chat.
4. **Subagents are child sessions behind one `task`/`subagent` tool.**
   - Each child gets a fresh context, its own prompt and permissions, and a depth limit of 1. The result returns as
     the tool output, wrapped in `<task id=… state=…>`. A `task_id`/`sessionID` lets the parent resume the child.
   - Background mode notifies the parent by injecting a synthetic user message.
   - We can rebuild this in our harness layer on top of plain OpenHands conversations, because OpenHands'
     `task`/`delegate` tools are broken in 1.59.0.
5. **A real permission ruleset with last-match-wins.**
   - Rules have the shape `{permission, pattern, action: allow|ask|deny}`. Bash patterns come from parsed commands.
   - "Always allow" stores a **command-prefix** pattern found from an arity table (`git checkout *`, `npm run dev *`)
     for the session.
   - "Reject" may carry feedback that is passed to the model verbatim, and an explicit deny tells the model which rule
     blocked it.
   - This replaces our stored-but-unenforced `permissions.allow/deny`.
6. **Doom-loop guard.** Three consecutive identical tool calls (same tool, same JSON input) trigger a `doom_loop`
   permission ask ([v1] `packages/opencode/src/session/processor.ts:29,352-378`). This is cheap to add in our app.
7. **Load rules files into the system prompt instead of asking the agent to read them.**
   - The first `AGENTS.md`, else `CLAUDE.md`, found walking up from the cwd is injected. So are the global
     `~/.config/opencode/AGENTS.md` (else `~/.claude/CLAUDE.md`) and the `instructions` globs/URLs.
   - Nested `AGENTS.md` files are attached as a `<system-reminder>` when the agent reads a file below them.
   - v2 freezes the set at session start, for caching, and delivers later changes as deltas near the tail.
8. **Compaction with an anchored, structured summary.**
   - The template has fixed sections: Objective / Important Details / Work State (Completed, Active, Blocked) /
     Next Move / Relevant Files.
   - It merges with the previous summary and keeps a recent tail verbatim.
   - After compaction it auto-continues with "Continue if you have next steps, or stop and ask for clarification if
     you are unsure how to proceed."
9. **Truncate tool output and save the rest to a file.** Above 2,000 lines or 50 KB, the result is a preview plus
   "Full output saved to: <file>. Use Grep … or Read with offset/limit", or "delegate to explore" when subagents are
   allowed.
10. **Per-model-family prompts with explicit persistence and steering rules.**
    - Examples: "Persist until the task is fully handled end-to-end within the current turn", "assume the user wants
      you to make code changes".
    - In v2: "treat new messages received during ongoing work as steering the active task rather than replacing it".
    - A max-steps prompt forces a text-only wrap-up.

---

## 2. Topic by topic

### 2.1 Modes and agents (Plan vs Build, primary vs subagent)

**How opencode does it**

- **An agent is a named profile:** `{name, description, mode: primary|subagent|all, hidden, model, variant, prompt,
  temperature, topP, color, steps, permission, options}` ([v1] `packages/opencode/src/agent/agent.ts:35-55`).
  - v2 is the same idea with `system` instead of `prompt` and `permissions` as an ordered rule list
    ([dev] `packages/schema/src/agent.ts:22-54`).
  - The default ruleset allows `*` and asks for `*.env` / `*.env.*`, but allows `*.env.example`
    ([dev] `packages/schema/src/agent.ts:46-51`).
- **Built-ins in v1** ([v1] `agent/agent.ts:119-265`):
  - `build`: primary. Defaults, plus `question: allow`, `plan_enter: allow`.
  - `plan`: primary. `question: allow`, `plan_exit: allow`, `task: {general: deny}`, and
    `edit: {"*": deny, ".opencode/plans/*.md": allow, <data>/plans/*.md: allow}` (`:156-181`). **Bash is not
    restricted by permission.** The docs say so explicitly: "Does not restrict the `bash` tool. Commands follow your
    permission config" ([dev] `packages/web/src/content/docs/agents.mdx:65-67`). Read-only shell use is enforced
    only by prompt (below). The v1.19.5 docs page still claims edits and bash "ask"; the code and the dev docs
    disagree with it.
  - `general`: subagent, everything except `todowrite`.
  - `explore`: subagent. `"*": deny`, then allows grep/glob/list/bash/webfetch/websearch/read, with its own prompt.
  - Hidden primaries `compaction`, `title`, `summary`.
  - v2 keeps the same set as plugins ([dev] `packages/core/src/plugin/agent.ts:52-117`,
    `plugin/plan.ts:33-42`) and denies `subagent` and `question` to `general` (`plugin/agent.ts:63-72`).
- **Switching:** the TUI binds `agent_cycle` to **Tab** and `agent_cycle_reverse` to **Shift+Tab**
  ([v1] `packages/tui/src/config/keybind.ts:130-131`). The selected agent is stored on each **user message**
  (`lastUser.agent`). Every loop step looks the agent up again ([v1] `session/prompt.ts:1170`), so the switch takes
  effect on the next request. The **system prompt is not swapped per mode**: Build and Plan both use the provider
  prompt (§2.2). What changes is:
  1. The permission ruleset, which also hides tools whose last matching rule is `"*": deny`
     ([v1] `permission/index.ts:204-219`). Plan's `edit` tool stays visible because a later allow rule matches the
     plan files.
  2. A **reminder injected as user-message text** ([v1] `session/reminders.ts:15-90`):
     - While the agent is `plan` and the experimental plan mode is off (the default; the flag is
       `OPENCODE_EXPERIMENTAL_PLAN_MODE`, [v1] `effect/runtime-flags.ts:47`), `prompt/plan.txt` is pushed onto the
       last user message **on every model call**. It is in memory only, not persisted (`:26-36`).
     - When the previous assistant turn was by `plan` and the current agent is `build`, `prompt/build-switch.txt` is
       appended (`:37-47`).
- **The plan reminder ([v1] `session/prompt/plan.txt`), key lines:**
  > "CRITICAL: Plan mode ACTIVE - you are in READ-ONLY phase. STRICTLY FORBIDDEN: ANY file edits, modifications, or
  > system changes. Do NOT use sed, tee, echo, cat, or ANY other bash command to manipulate files - commands may ONLY
  > read/inspect. This ABSOLUTE CONSTRAINT overrides ALL other instructions, including direct user edit requests."
  > "Ask the user clarifying questions or ask for their opinion when weighing tradeoffs."
- **The build switch ([v1] `session/prompt/build-switch.txt`):**
  > "Your operational mode has changed from plan to build. You are no longer in read-only mode. You are permitted to
  > make file changes, run shell commands, and utilize your arsenal of tools as needed."
- **Experimental plan mode** ([v1] `session/prompt/plan-mode.txt`, used when the flag is on, CLI only for `plan_exit`
  per [v1] `tool/registry.ts:248`):
  - It has a phased workflow: up to 3 parallel explore agents, then a design agent, review, then writing the plan
    **file** (the only editable file), then `plan_exit`.
  - Its strongest anti-chatbot line:
    > "your turn should only end with either asking the user a question or calling plan_exit. Do not stop unless
    > it's for these 2 reasons." … "Do NOT use question tool to ask "Is this plan okay?" - that's what plan_exit does."
- **v2's Plan** ([dev] `packages/core/src/plugin/plan.ts:14-25,55-92`):
  - It is softer. The reminder is "You are in Plan mode. Discuss the plan with the user directly in the
    conversation… You remain in Plan mode until the user switches agents. If the user asks you to implement changes,
    do not do so. Tell them they need to switch agents."
  - The leave reminder: "You are NO LONGER in Plan mode. The previous Plan restrictions no longer apply."
  - The reminders are persisted as synthetic user messages on `session.created` / `session.agent.selected`.
  - A `context` hook **re-inserts the reminder when compaction or a revert has stripped it**. It puts it before the
    user's prompt, "appending near the tail so the cached prefix stays warm" (`:55-66`).
  - A refused edit is rewritten to "Cannot use edit to modify files outside the Plan directory: <dir>" (`:44-53`).
- **Subagents:**
  - Primaries see subagents through the `task` tool description, which lists every non-primary agent with its
    description ([v1] `tool/registry.ts:266-277`). The user can force one with `@name` in a message.
  - `@` parts set `bypassAgentCheck` so the permission ask is skipped ([v1] `session/prompt.ts:1223`; docs
    "Users can always invoke any subagent directly via the `@` autocomplete menu").
  - **Spawning** ([v1] `tool/task.ts:92-224`):
    - Depth is checked against `subagent_depth` (default 1).
    - It asks `task` permission for the `subagent_type` and creates a **child session** (`parentID`, title
      "<description> (@agent subagent)").
    - The child's permission is the parent's **deny and external_directory rules**, plus default denies of
      `todowrite` and `task` unless the subagent allows them ([v1] `agent/subagent-permissions.ts:14-27`).
    - The model defaults to the parent's. It runs a normal prompt loop in the child.
    - It returns the child's **last text part**, wrapped as `<task id="…" state="completed"><task_result>…</task_result></task>`
      (`:64-79`).
  - **Background mode** returns at once with "DO NOT sleep, poll for progress… Work on non-overlapping tasks, or
    briefly tell the user what you launched and end your response". On completion it **injects a synthetic user
    message** with the `<task>` block (`:25-41,227-254`). In v1 it is behind `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS`.
  - v2 renames the tool `subagent`, adds an optional `model` and `sessionID` follow-ups, and keeps the same wording
    ([dev] `tool/plugin/subagent.ts:19-62`).
  - The `task` description is in [v1] `tool/task.txt`. It covers when not to use it, launching in parallel, "The
    result returned by the agent is not visible to the user", "your prompt should contain a highly detailed task
    description… and you should specify exactly what information the agent should return", and "Clearly tell the
    agent whether you expect it to write code or just to do research".

**EveryAI today**

- Modes Ask / Auto-edit / Plan / Full auto are **app-side approval policies** over OpenHands `AlwaysConfirm`.
  Full auto uses `NeverConfirm` (`frontend/lib/features/code/domain/agent_mode.dart:22-50`).
- Plan refuses non-read-only actions with `planRefusal`, then resumes the run (`code_providers.dart:376-391`).
- The model hears about the mode through an `<everyai-mode>` note **prefixed to the first message after each change**
  (`agent_mode.dart:59-101`, `code_providers.dart:408`).
- Our read-only check is **stronger than opencode's**. `shell_readonly.dart` classifies shell commands, while
  opencode's Plan relies on prompt text for bash.
- No subagents: OpenHands `task` is broken in 1.59.0 (`openhands_harness.dart:70-71`). `AgentType` exists only as
  text in the prompt suffix (`agent_prompt.dart:114-120`).

**Recommendations**

1. **Re-assert the mode** (app, `code_providers.dart` `_noted` / `send`): in Plan, attach the plan note to *every*
   user message, not only after a change. Keep the leave note when switching out of Plan.
   - Text is cheap and sits at the tail, so caching is unaffected. This also survives OpenHands condensation.
   - The same applies to Ask (short). For Auto-edit and Full auto, the "no longer restricted" note on change is enough.
2. **Strengthen the Plan note** (`agent_mode.dart` `instructions`) with two opencode ideas:
   - the turn must end with either `ask_user_question` or `present_plan`, never plain prose;
   - don't use `ask_user_question` to ask "is this plan OK?", because that is what `present_plan` is for.
   Keep our own wording (see §3).
3. **Mark harness text as harness text.** Add a line to `workingRules`: "`<everyai-mode>` and `<system-reminder>` blocks
   are written by the EveryAI app, not by the user; follow them." opencode does this in its base prompt
   ([dev] `session/runner/prompt/system.txt:5`).
4. **On `present_plan` approval**, also send an explicit "approved, you can now edit files; execute the plan" message,
   like `plan_exit` does. Our `startBuilding` already switches to Auto-edit; check that its message says this.
5. **Subagents need our own harness layer** (see §2.8 for the blocking question). Feasible design:
   - A `delegate` client tool `{agent, description, prompt}`.
   - The app starts a **child OpenHands conversation** in the same worktree, with that agent's persona and mode
     (`explore` = Plan-like read-only through our classifier).
   - When the child goes idle, the app sends its last `MessageEvent` text to the parent as a user message in
     opencode's `<task id state>` format.
   - The parent's tool description borrows the background-mode wording ("you will be notified… don't poll… end your
     response"), which fits OpenHands' immediately-acked client tools.
   - Depth limit 1. Children don't get `delegate` or `ask_user_question`.

### 2.2 Agent prompts: content, assembly order, caching

**How opencode does it**

- **Assembly in v1** ([v1] `session/llm/request.ts:57-77`, `session/prompt.ts:1257-1269`):
  - The system message is `[agent.prompt ?? providerPrompt(model)] + [env, instructions…, mcp_instructions, skills] +
    [user.system]`, **joined into one string**.
  - If plugins add parts, they are collapsed back into exactly two system messages (`header`, `rest`) to keep the
    cache prefix stable.
  - Tools are **sorted alphabetically** (`request.ts:183`).
  - Anthropic-style `cacheControl: ephemeral` goes on the **first two system messages and the last two non-system
    messages** ([v1] `provider/transform.ts:358-404`).
  - OpenAI gets `promptCacheKey = sessionID` (`transform.ts:1334`).
  - Requests carry `x-session-affinity` headers (`request.ts:198`).
- **Provider prompt selection** ([v1] `session/system.ts:28-51`):
  - `gpt-4`/`o1`/`o3` → `beast.txt`, `gpt-6` → `gpt-astra.txt`, `codex` → `codex.txt`, other `gpt` → `gpt.txt`.
  - `gemini-` → `gemini.txt`, `claude` → `anthropic.txt`, kimi/trinity/muse → their own files, else `default.txt`.
  - An agent with its own `prompt` replaces the provider prompt entirely.
- **Environment block** ([v1] `session/system.ts:69-104`): "You are powered by the model named …", then
  `<env>` with the working directory, workspace root, git repo yes/no, platform and today's date, then
  `<available_references>`.
- **v2 is much smaller** ([dev] `session/runner/prompt/system.txt`, 15 lines):
  - The base prompt is "You are an AI agent running in OpenCode, a coding agent harness…" plus tool guidance generated
    from the tool set ([dev] `session/system-prompt.ts:9-28`). One generated line: "Do not chain shell commands with
    separators like `echo "====";`…".
  - Model plugins override it (`gpt.txt`) or append to it (Claude gets only a 2-line comment-density note)
    ([dev] `plugin/optimize.ts:16-30,78-103`, `plugin/system-prompt/anthropic.txt`).
  - Instructions (date, env, AGENTS.md) are a **second system part that is frozen when the session starts**. Later
    changes arrive as rendered deltas ("Today's date is now: …") near the tail ([dev] `instructions/builtins.ts:22-50`,
    `session/instruction-state.ts:21-60,195-210`, `session/model-request.ts:99-119`).
  - On the last allowed step the tools stay in the request with `toolChoice: none`, "to preserve the provider's
    cached prefix" ([dev] `session/runner/llm.ts:263-268`).
- **Passages that push agentic behaviour** (quoted):
  - [v1] `prompt/gpt.txt:17-19`:
    > "Unless the user explicitly asks for a plan, asks a question about the code, is brainstorming potential
    > solutions, or some other intent that makes it clear that code should not be written, assume the user wants you
    > to make code changes or run tools to solve the user's problem. In these cases, it's bad to output your proposed
    > solution in a message, you should go ahead and actually implement the change. … Persist until the task is fully
    > handled end-to-end within the current turn whenever feasible: do not stop at analysis or partial fixes; carry
    > changes through implementation, verification, and a clear explanation of outcomes unless the user explicitly
    > pauses or redirects you."
  - [dev] `plugin/system-prompt/gpt.txt:17`:
    > "By default, treat new messages received during ongoing work as steering the active task rather than replacing
    > it. Incorporate corrections and constraints, and answer questions briefly in commentary before continuing."
  - [v1] `prompt/anthropic.txt:23-27,79-96` pushes TodoWrite "VERY frequently" and delegation to the Task tool for
    non-needle searches. Its wording is close to an older Claude Code system prompt (see §3, License).
  - [v1] `prompt/default.txt:75`: run lint/typecheck when done. If you can't find the command, ask, then "proactively
    suggest writing it to AGENTS.md".
- **Max steps:** when `agent.steps` is reached, the loop appends an assistant message `MAX_STEPS_PROMPT`. It begins
  "CRITICAL - MAXIMUM STEPS REACHED … Tools are disabled until next user input. Respond with text only." and requires
  a summary of what was done, what remains, and next steps ([v1] `packages/core/src/session/runner/max-steps.ts:1-16`,
  `session/prompt.ts:1178-1181,1281`).

**EveryAI today**

- `persona` replaces OpenHands' persona and workflow sections. `system_message_suffix` = `workingRules` + attribution
  rules + project rules + agent types (`agent_prompt.dart:7-122`, `openhands_harness.dart:73-74`). It is constant per
  session (good for caching).
- One persona for every model. The gateway injects cache breakpoints (CLAUDE.md "Prompt caching"). There is no env
  block of our own (OpenHands adds its own; unverified what it contains in 1.59).
- AGENTS.md is **read by the agent on request** ("Read AGENTS.md, CLAUDE.md or the README… when present",
  `agent_prompt.dart:23-24`), not injected.

**Recommendations**

1. **Inject rules files at session creation** (`settings.dart` `agentPromptFor`): see §2.4.
2. **Per-family addendum** (`agent_prompt.dart`): keep the shared persona and add a short family block chosen from
   `spec.model` (`anthropic/*`, `openai/*`, `google/*`, Chinese free models). Seed the non-Claude blocks with the
   persistence and steering ideas above, rewritten in our words. Feasible inside OpenHands (it's just suffix text).
3. **Steering sentence:** our ⌥Enter "steer" interrupts and sends a message. Add a working rule saying mid-run
   messages steer the current task rather than replace it. That is opencode v2's wording, and it matches our queue
   and steer UI.
4. **A step budget is optional.** OpenHands has `max_iterations` on conversation create (CLAUDE.md protocol notes).
   opencode's wrap-up prompt is the useful part. If we set `max_iterations`, have the app send a "summarize what's
   done / what's left" message when the run stops for that reason (unverified how OpenHands reports it).

### 2.3 Custom agents

**How opencode does it**

- **Markdown with frontmatter:**
  - v1 globs `{agent,agents}/**/*.md` in every config directory. The file name is the agent name, the frontmatter is
    the config and the body is the prompt ([v1] `config/agent.ts:11-32`). Legacy `{mode,modes}/*.md` become primaries
    (`:34-59`).
  - Locations: `~/.config/opencode/agents/` and `.opencode/agents/`, discovered from the cwd up to the project root.
    Nested paths become IDs (`team/reviewer`) ([dev] `services/www/src/docs/content/agents.mdx:32-45`).
- **JSON:** `agent: {name: {...}}` in v1 `opencode.json`, `agents` in v2.
- **Fields in v1:** description, mode (default `all` for custom agents, [v1] `agent/agent.ts:273-280`), model
  (`provider/model`), variant, prompt, temperature, top_p, color, hidden, steps, options, permission, disable
  (`agent/agent.ts:267-294`).
- **Fields in v2:** `system`, `request`, `permissions`, a list of `{action, resource, effect}`, and `model:
  provider/model#variant` ([dev] `services/www/…/agents.mdx:5-22,181-330`).
- **Merging:** config entries merge onto built-ins by name (overriding `build` works). v2: "Later scalar values replace
  earlier values, request maps merge by key, and permission rules append"; global permissions apply before agent rules
  ([dev] `agents.mdx:160-180`).
- **Selection:** `default_agent` must be a visible primary ([v1] `agent/agent.ts:328-340`). Subagents use the
  caller's model unless they set one (docs agents "Model").
- **`task` permission** on the caller, with glob patterns, controls which subagents it may launch. A denied subagent
  is **removed from the task tool description** (docs agents "Task permissions").
- **`opencode agent create`** generates an agent with an LLM that returns `{identifier, whenToUse, systemPrompt}` from
  a description, avoiding existing names ([v1] `agent/agent.ts:368-436`, prompt `agent/generate.txt`).

**EveryAI today:** `agents: {name: {description, prompt}}` in settings JSON, rendered as an `<AGENT_TYPES>` list. The
agent can't spawn them (`agent_settings.dart:17-29,90-98`).

**Recommendations** (settings layer; the spawning needs §2.1 rec 5)

- Read `.everyai/agents/*.md` (project), `<App Support>/agents/*.md` (user) and, for compatibility,
  `.opencode/agents/*.md` and `.claude/agents/*.md`.
- Frontmatter: `description`, `mode` (`primary` / `subagent` / `all`), `model` (gateway id), `effort` (ties into
  `/v1/agents` tiers), `permission` (same shape as §2.5), `hidden`. The body is the prompt.
- **Primary custom agents become extra modes** in the composer's mode menu. They are a persona/suffix swap, and
  OpenHands fixes `persona` at conversation create, so switching to one mid-session means a new conversation or a
  mode-note-style reminder. Plan for that.
- Keep the JSON `agents` key as a second source. Merge by name and append rules, as opencode v2 does.

### 2.4 AGENTS.md and rules

**How opencode does it** ([v1] `session/instruction.ts`)

- **Global:** the first existing of `~/.config/opencode/AGENTS.md` and `~/.claude/CLAUDE.md` (`:59-62,114-119`).
- **Project:** for each name in `["AGENTS.md", "CLAUDE.md", "CONTEXT.md"]` in order, `findUp` from cwd to worktree root
  collects **all** matches of that name. The first name with any match wins, so CLAUDE.md is used only when no
  AGENTS.md exists (`:63-67,121-132`).
- **`instructions` config:** relative globs are searched upward, plus absolute paths, `~/` paths, and http(s) URLs
  fetched with a 5 s timeout (`:134-168`; docs rules "Custom Instructions").
- **Injection:** each file becomes `Instructions from: <path>\n<content>` in the system block, after the env block
  and before MCP and skills ([v1] `session/prompt.ts:1264-1269`).
- **Nested rules on read:** when `read` opens a file, opencode walks from the file's directory up to the project root.
  Any `AGENTS.md` not already loaded is appended to the read result as `<system-reminder>Instructions from: …`,
  once per message ([v1] `session/instruction.ts:178-220`, `tool/read.ts:300,355-356`).
- **Opt-outs:** `OPENCODE_DISABLE_CLAUDE_CODE`, `…_PROMPT` and `…_SKILLS` disable the Claude fallbacks (docs rules).
- **`/init`** writes or updates AGENTS.md with build/test commands, non-obvious architecture and gotchas (docs rules
  "Initialize").

**EveryAI today:** the persona tells the agent to read AGENTS.md / CLAUDE.md / README. `settings.instructions` (a list
of strings) goes into `<PROJECT_RULES>`.

**Recommendations** (`settings.dart` / `settings_io.dart`, feasible inside OpenHands)

- At session start, read `AGENTS.md` (else `CLAUDE.md`) at the worktree root and its ancestors up to the repo root,
  plus a user-global `AGENTS.md` (App Support, falling back to `~/.claude/CLAUDE.md`).
- Append them to `system_message_suffix` as `Instructions from: <path>` blocks, frozen for the session (the v2 cache
  rule). Cap the size and log what was loaded.
- Treat `settings.instructions` entries that look like paths or globs as files to load, as opencode's `instructions`
  does.
- Nested-on-read can't be hooked inside OpenHands' `file_editor`. Instead, the app can watch `FileEditorAction view`
  events and send newly relevant nested AGENTS.md as a reminder on the next user message. Low priority.
- Unverified: whether OpenHands 1.59 already loads AGENTS.md itself (as a "repo skill"). Check the SystemPromptEvent
  before shipping, to avoid duplicates.

### 2.5 Settings and permissions

**How opencode does it**

- **Layering, merged per key** (docs config "Precedence order", [v1] `config/config.ts:380-450`):
  1. remote `.well-known/opencode`
  2. global `~/.config/opencode/opencode.json`
  3. `OPENCODE_CONFIG`
  4. project `opencode.json` (found upward)
  5. `.opencode/` directories (agents, commands, plugins)
  6. `OPENCODE_CONFIG_CONTENT`
  7. managed files
  8. macOS MDM (highest)
- **Permission model** ([v1] `permission/index.ts:28-38,182-219`; docs permissions):
  - Config `permission: {tool: action | {pattern: action}}` becomes an ordered list of rules. `evaluate` takes the
    **last** rule where both the permission and the pattern wildcard-match. **No match means `ask`**.
  - Agent rulesets are `merge(defaults, agentSpecific, userConfig)`; later wins.
  - Keys: read, edit (covers edit/write/patch), glob, grep, bash, task, skill, lsp, question, webfetch, websearch,
    `external_directory`, `doom_loop`.
  - Defaults: `*` allow; `doom_loop` and `external_directory` ask; `.env` reads ask (docs say deny, code says ask:
    [v1] `agent/agent.ts:119-136`).
  - `opencode --auto` auto-approves everything that isn't explicitly denied.
- **Bash patterns** ([v1] `tool/shell.ts:378-412`, `permission/arity.ts`):
  - The command is parsed with tree-sitter (bash or PowerShell). Each simple command adds its full source text as a
    pattern to check.
  - It also adds an "always" pattern made of the **arity prefix + ` *`**, from a table (`git` = 2, `npm run` = 3,
    `cat` = 1, …). Approving "always" for `git checkout main` therefore stores `git checkout *` for the session.
  - Paths outside the project in file commands raise `external_directory`.
- **The "ask" UI** ([v1] `permission/index.ts:66-170`; docs permissions "What Ask Does"):
  - `once` | `always` (adds the request's `always` patterns to the session's approved list and auto-resolves other
    pending asks they now cover) | `reject` (optional **message**).
  - Reject fails **all** pending asks in the session.
- **What the model sees** ([v1] `packages/core/src/v1/permission.ts:7-27`):
  - Plain reject: "The user rejected permission to use this specific tool call."
  - Reject with feedback: "…with the following feedback: <msg>".
  - Deny rule: "The user has specified a rule which prevents you from using this specific tool call. Here are some of
    the relevant rules <json>".
  - By default a reject **stops the loop**; `experimental.continue_loop_on_deny` keeps it going
    ([v1] `session/processor.ts:647`).
- **Other settings:**
  - `model`; `small_model` for titles/summaries (falls back to a cheaper model from the same provider); `compaction
    {auto, prune, reserved}`; `snapshot` (bool); `instructions`; formatters; LSP; MCP; `tool_output {max_lines,
    max_bytes}`; `subagent_depth`; `default_agent`. (Docs config sections "Models", "Compaction", "Snapshot",
    "Formatters", "LSP Servers", "MCP servers".)
  - Provider options `timeout`, `chunkTimeout` (abort if no chunk for N ms), `setCacheKey`.

**EveryAI today:**

- Layers: user `<App Support>/settings.json` → project `.everyai/settings.json` → `.everyai/settings.local.json`.
  Scalars override, lists append (`agent_settings.dart:104-125`, `settings_io.dart:9-15`). That matches opencode's
  merge semantics.
- `permissions.allow/deny` are "stored; not enforced yet" (`agent_settings.dart:66-68`).
- Approval UI: approve / deny with an optional reason (`code_providers.dart:460-468`).

**Recommendations** (`agent_settings.dart`, `agent_mode.dart`, `code_providers.dart` `_autoRespond`; feasible app-side)

- Adopt the rule shape `permission: {"bash": {"*": "ask", "git status*": "allow", "rm *": "deny"}, "edit": {...},
  "external_directory": {...}}` with last-match-wins. The mode supplies the base ruleset, then user, project and
  local settings append.
- Classify our OpenHands action kinds into permission keys: `TerminalAction` → bash with the command string,
  `FileEditorAction` view → read, other edits → edit with the path, client tools → their names.
- **Session "always allow"** with an arity-prefix table. A port of `arity.ts` is about 160 lines and MIT; keep the
  notice. Show the stored prefix in the approval card ("Always allow `npm run *`").
- **Deny with reason** already exists. Also send the matched rule on a settings-deny, as opencode does, so the model
  knows it's policy and not a failure.
- **Full auto caveat:** with `NeverConfirm`, deny rules can't be enforced. To honour `deny` in Full auto, keep
  `AlwaysConfirm` and auto-approve in the app. That costs one confirmation round-trip per action; measure it before
  switching. Alternatively, use `NeverConfirm` only when the merged ruleset has no deny or ask rules.

### 2.6 Git, worktrees, checkpoints

**How opencode does it**

- **Snapshots in a shadow git repository:** `--git-dir <data>/snapshot/<projectID>/<hash(worktree)> --work-tree
  <worktree>`. It never touches the user's `.git` ([v1] `snapshot/index.ts:65-75,318-341`). It is tuned for large repos
  (`feature.manyFiles`, `index.version 4`, untracked cache) and skips untracked files over 2 MB (`:24,277-297`).
- **Granularity is per model step, not per user turn.**
  - `track()` (write-tree) runs at `step-start`; at `finish-step` it diffs and stores a `patch` part `{hash, files}`
    on the assistant message ([v1] `session/processor.ts:102,424-436,470-482`).
  - **Revert** to any message or part:
    - It undoes the patches after that point and remembers a snapshot of the current state, so **unrevert** (redo)
      works.
    - It recomputes the session diff ([v1] `session/revert.ts:38-89,91-99`).
    - The reverted messages are deleted only when the user sends the next prompt (`cleanup`, `:101-124`).
  - `snapshot: false` turns it off (docs config "Snapshot").
- **Worktrees:** a separate, user-driven feature. `git worktree add --no-checkout -b opencode/<name> <data>/worktree/<projectID>/<name>`,
  then `reset --hard` and an optional start command ([v1] `worktree/index.ts:183-237`). It is not automatic per
  session.

**EveryAI today:**

- An automatic worktree per session on `everyai/<slug>` under App Support.
- Per-**user-turn** checkpoints as commits under `refs/everyai/<slug>/turn-N`, built through a throwaway
  `GIT_INDEX_FILE` so the user's index is untouched (`git_service_io.dart:99-172`).
- Restore = `clean -fdq` + `restore --source`. Then squash merge, PR and hunk revert.
- **We are ahead on isolation** (worktrees by default) and roughly level on checkpoints.

**Recommendations** (low priority)

1. **Redo:** before `restoreCheckpoint`, take a checkpoint of the current state (`turn-N-undo`) so "Restore files" can
   be undone. This is opencode's `rev.snapshot` (`code_providers.dart` `rewind`).
2. **Transcript rewind** to match file rewind: OpenHands exposes `/fork` and `/navigate` (CLAUDE.md protocol notes).
   Forking at the rewound turn would line up conversation and files, as opencode's revert does. Unverified how fork
   behaves in 1.59.
3. **Per-step granularity** would need a checkpoint per `ObservationEvent` of a `FileEditorAction` or `TerminalAction`.
   That is possible app-side but costs a `write-tree` per step. Defer unless users ask for "undo this edit".

### 2.7 Robustness

**Truncated output (max tokens)**

- **v1:**
  - A tool call with unparsable JSON is "repaired" into a call to the hidden `invalid` tool. Its result is "The
    arguments provided to the tool are invalid: <error>" ([v1] `session/llm.ts:295-316`, `tool/invalid.ts`).
  - The loop continues while the last assistant message has tool parts, even when finish ≠ `tool-calls`
    ([v1] `session/prompt.ts:1103-1130`). So a truncated call becomes an error the model reads, and it tries again.
  - A truncated **text** answer just ends the loop.
  - The output cap is `min(model.limit.output, 32_000)` ([v1] `provider/transform.ts:18,1481-1483`).
- **v2** ([dev]):
  - Finish reason `length` with unfinished tool input fails each call with the specific `length` message and an
    excerpt of up to 2,048 chars (`runner/publish-llm-event.ts:30-56,358-367,664-671`).
  - If tools ran, the loop just continues (the results go back).
  - If not, it publishes the synthetic `CONTINUE_AFTER_OUTPUT_LIMIT`. Three consecutive `length` finishes fail the step
    with "Response still truncated after two output token limit continuations" (`runner/llm.ts:40-41,336-366`).
  - The output limit is the catalog output (fallback 32K, max 256K), **reduced to the room left in the window**, with
    15% estimate error and 1% headroom, minimum 1,024 (`session/model-request.ts:47-97`).
- **Stream cut mid-response:**
  - Before any output: a transparent retry.
  - After output started: keep the partial and continue with "The previous response was interrupted. Continue from
    where you left off without repeating completed content." ([dev] `runner/llm.ts:37-38,327-335`,
    `runner/step.ts:261-268`).

**Empty responses:** no dedicated handling found in either line, beyond content-filter finishes. v1 turns
`content-filter` into a visible error instead of going idle silently ([v1] `session/prompt.ts:1297-1308`). Unverified
whether something elsewhere handles empty turns.

**Doom loops:**

- v1: if the last 3 parts of the current assistant message are calls to the same tool with identical JSON input, it
  asks permission `doom_loop` (default `ask`) ([v1] `session/processor.ts:29,352-378`).
- No equivalent found in [dev] core (`grep doom` hits only the v1 config schema).
- OpenHands has its own stuck detector (our `ExecutionStatus.stuck`).

**Retries:**

- v1: retries on 429/5xx/overloaded/network patterns. Delay = `retry-after-ms` or `retry-after` header (seconds or
  HTTP date), else exponential from 2 s ×2 with 25% jitter, capped at 30 s without headers. The UI shows a "retry"
  status with attempt and next time ([v1] `session/retry.ts:26-41,47-80`, `session/processor.ts:672-686`).
- v2: exponential from 2 s, capped at 10 s per gap, 10 retries (about 84 s in total), jittered, honouring retry-after
  up to 15 min. Timeouts retry at most 3 times. One-shot calls retry only when the provider clearly never ran them
  (429, 503/529, connection refused), because they may be billed per attempt ([dev] `packages/core/src/model-retry.ts:11-104`).

**Compaction:**

- **Trigger:**
  - v1: total tokens ≥ usable, where usable = `limit.input − min(20K, maxOutput)` (or `context − maxOutput`)
    ([v1] `session/overflow.ts:6-32`). It is checked after each finished step and on provider "context overflow"
    errors (`session/processor.ts:490-496,619-633`).
  - v2: ceiling = window − max(15% of window, 16K). A background summary is **precomputed at 85%** for sessions above
    64K tokens, so the swap is instant. Rejected summary requests are shrunk 85% → 70% → 50% → 35%
    ([dev] `session/compaction.ts:124-168,1133-1141`).
- **What is kept:** a recent tail of 2K–15K tokens of whole turns stays verbatim ([v1] `session/compaction.ts:32-33,225-268`).
  Old tool outputs in the summarized part are cut to 2,000 chars (`:30,51-82`).
- **Optional `prune`:** walking backwards, protects the newest 40K tokens of tool output and clears older outputs to
  "[Old tool result content cleared]" if that frees more than 20K (`:28-31,271-316`).
- **Summary prompt:** the compaction agent's system prompt is "You are a context summarization agent… produce a
  structured summary… so another coding agent can continue the work… Do not continue the conversation. Do not
  respond to any questions in the conversation." ([v1] `agent/prompt/compaction.txt`). The user message carries
  `<conversation>…</conversation>` plus this template ([v1] `packages/core/src/session/compaction.ts:15-55,160-174`):

  ```
  ## Objective / ## Important Details / ## Work State (### Completed, ### Active, ### Blocked) /
  ## Next Move (1. 2.) / ## Relevant Files
  Rules: Keep every section, even when empty. Use terse bullets… Preserve exact file paths, symbols, commands,
  error strings, URLs, and identifiers… Do not mention the summary process or that context was compacted.
  ```

  When there is a prior summary: "The <prior-summary> is discarded after this: anything you do not carry into the new
  summary is lost… Where they conflict, the conversation wins… Move completed work from "Active" to "Completed"."
- **After auto-compaction**, a synthetic user message: "Continue if you have next steps, or stop and ask for
  clarification if you are unsure how to proceed." ([v1] `session/compaction.ts:524-545`).

**Tool output truncation:**

- Limits are 2,000 lines / 50 KB by default (configurable via `tool_output`). Head or tail is kept. The full text goes
  to a retention dir (7 days).
- The model is told: "The tool call succeeded but the output was truncated. Full output saved to: <file>. Use Grep to
  search the full content or Read with offset/limit to view specific sections." If the agent can use `task`: "Use the
  Task tool to have explore agent process this file… Do NOT read the full file yourself - delegate to save context."
  ([v1] `tool/truncate.ts:12-17,85-140`).

**EveryAI today**

- `maxOutputTokens` is 64,000 (`harness.dart:18`). The gateway maps Anthropic `max_tokens` to finish `length`
  (`backend-exp/src/anthropic.zig:391`) and defaults `max_tokens` to 32,000 when absent (`:111-113`).
- No output-limit recovery. `retry()` sends "Carry on from where you stopped." for `stuck` (`code_providers.dart:446-452`).
- OpenHands owns condensation, retries and terminal-output truncation. Its settings are unverified for 1.59.

**Recommendations**

1. **Gateway-level output-limit recovery** (`backend-exp/src/gateway.zig`, model-agnostic, invisible to OpenHands):
   - When an upstream response ends with `finish_reason: length` **and** the last tool call's arguments don't parse,
     make **one** follow-up upstream call. It contains the original messages + the partial assistant turn + a user
     message adapted from opencode v2: "Your last response hit the output token limit before the tool call
     arguments were complete, so it was not run. Break large payloads into smaller tool calls (e.g. create the file
     in parts, or edit in several str_replace calls) and reissue it."
   - Stream that answer to OpenHands as if it were the original. Cap at 2 follow-ups; bill both calls; record a
     `usage_events` flag.
   - This fixes the "stuck after truncated whole-file write" class at the root. With text-only truncation, pass it
     through.
2. **App fallback** (`code_providers.dart`): when a run ends in `error`/`stuck` right after a turn whose usage shows
   completion tokens ≈ the cap, auto-send opencode's `CONTINUE_AFTER_OUTPUT_LIMIT` wording once, instead of showing
   Retry.
3. **Fit `max_tokens` to the remaining window** in the gateway, as in [dev] `model-request.ts:89-97`. This avoids
   400s near the end of long sessions when 64K output + a large prompt exceeds the window.
4. **Doom-loop guard** (`domain/transcript.dart` + controller): with 3 consecutive `ActionCall`s of the same tool and
   identical arguments, interrupt and show an approval card ("The agent repeated the same step 3 times"), even in Full
   auto.
5. **Compaction:** check whether the 1.59 conversation-create API accepts `agent.condenser` (LLMSummarizingCondenser)
   and a custom summary prompt (unverified). If it does, use opencode's template and a cheap model. If it doesn't, the
   gateway could summarize, but that is a much bigger change. Defer.
6. **Mid-stream cut:** the gateway's upstream streaming can use v2's distinction (no output yet → retry silently;
   output started → surface the error). Check that `gateway.zig` retries pre-output failures (not checked here).

### 2.8 Questions to the user, todos, plan presentation

**How opencode does it**

- **`question` tool:** input `{questions: [{question, header (≤30 chars), options: [{label (1–5 words), description}],
  multiple?}]}`; `custom` (a free-text answer) is on by default ([v1] `packages/schema/src/v1/question.ts:15-31`).
  - Description ([v1] `tool/question.txt`): "When `custom` is enabled (default), a "Type your own answer" option is
    added automatically; don't include "Other" or catch-all options… If you recommend a specific option, make that
    the first option in the list and add "(Recommended)" at the end of the label."
  - **It blocks:** `question.ask` awaits the user's reply. The result is "User has answered your questions:
    "<q>"="<a1, a2>", … You can now continue with the user's answers in mind." ([v1] `tool/question.ts:22-40`).
  - In v2, dismissing it ends the step without a model-facing result, unless the dismissal carries a message, which
    the model gets as feedback ([dev] `tool/plugin/question.ts:94-104`).
  - Allowed for build and plan, denied for subagents.
- **`todowrite`** ([v1] `tool/todowrite.txt`, `tool/todo.ts`):
  - Writes the full list `[{content, status: pending|in_progress|completed|cancelled, priority}]` and returns it as JSON.
  - Rules: use it for 3+ steps; exactly one `in_progress`; mark completed only after verification ("Never based on
    intent"); "If blocked or partial, keep it `in_progress` and add a follow-up todo describing the blocker";
    "Preserve user-provided commands verbatim".
  - Denied to subagents by default.
- **Plans:**
  - Default Plan mode presents the plan **in the conversation** (the v2 reminder says so).
  - The experimental v1 flow writes a markdown **plan file** (`.opencode/plans/*.md` or `<data>/plans/`), then calls
    `plan_exit`. That asks "Plan at <path> is complete. Would you like to switch to the build agent and start
    implementing?" Yes/No, with `custom: false`.
  - On Yes it creates a user message with `agent: build` and the text "The plan at <path> has been approved, you can
    now edit files. Execute the plan". On No it fails the call with a rejection ([v1] `tool/plan.ts:25-75`).

**EveryAI today:**

- `ask_user_question` (1–4 questions, 2–4 options, `multi_select`, "Other") and `present_plan` (`title, summary, steps
  [{title, detail, files}], risks, verification`) are **OpenHands client tools**: acked at once, "After calling this
  tool, stop and end your turn" (`agent_mode.dart:103-194`).
- OpenHands `task_tracker` stands in for todowrite (status `todo|in_progress|done`).

**Recommendations**

1. **Prompt tweaks, cheap** (`agent_mode.dart` specs):
   - Add the "(Recommended)" first-option convention and "don't add your own Other option, the app adds one".
   - Have `present_plan` lead to an explicit approval message on Start building: "Plan approved; you may now edit
     files. Build it, keep the task list current, verify, then report."
2. **Blocking answers inside the tool call (unverified, worth a spike):**
   - Register the client tools so they need confirmation (they arrive as pending actions under `AlwaysConfirm`).
   - Answer by `respond_to_confirmation {accept: false, reason: "<answers JSON + summary>"}` followed by `/run`.
     This is the same reject-with-reason path Plan mode already uses (`code_providers.dart:381-387`).
   - If OpenHands shows `rejection_reason` to the model as the observation, the agent receives the answers **as the
     tool result in the same turn**, which is opencode's semantics.
   - Risks: the model may read it as "rejected", so prefix the reason with "Not an error: the user answered: …".
     Full auto (`NeverConfirm`) would need a temporary policy switch.
   - If this fails, keep today's user-message path, but phrase the follow-up like opencode's ("User has answered your
     questions: … continue with these answers in mind").
3. **Task-list rules:** add opencode's todowrite rules to `workingRules` in our words, mapped onto `task_tracker`
   (statuses todo/in_progress/done): one in progress, done only after verification, add a follow-up item when blocked.
   It already renders as our PlanItem.

---

## 3. License note

- **opencode is MIT** (`LICENSE`, "Copyright (c) 2025 opencode"). We may copy code and prompt text, including verbatim,
  provided the copyright and permission notice ship with the copied portions. Add an opencode entry next to our
  OpenHands third-party notice.
- **Safe to copy (they appear original to opencode):**
  - v2 `session/runner/prompt/system.txt`, the v2 Plan enter/leave reminders (`plugin/plan.ts`), the compaction
    template and merge rules (`packages/core/src/session/compaction.ts`), the continuation and input-failure messages
    (`runner/llm.ts`, `runner/publish-llm-event.ts`), the truncation hints, `todowrite.txt`, `question.txt`,
    `task.txt`, the explore prompt, and the bash arity table.
- **Reimplement or rewrite instead:**
  - v1 `anthropic.txt` and `default.txt` closely follow an older Claude Code system prompt ("You are an interactive
    CLI tool that helps users with software engineering tasks", the TodoWrite examples, "IMPORTANT: You must NEVER
    generate or guess URLs…"). opencode's MIT grant covers only what opencode owns. Provenance is unverified, so
    don't copy these verbatim.
  - The GPT/Codex-style prompts (`gpt.txt`, `codex.txt`, `beast.txt`) resemble OpenAI Codex and community prompts.
    Codex CLI is Apache-2.0, but provenance is unverified here, so paraphrase the ideas.
- **Our product rules still apply:** anything copied must not name opencode or the model in agent-visible commit
  guidance, and prompts must not tell users about opencode keybindings (v1 prompts mention `ctrl+p`).
- Not legal advice. If we ship verbatim prompt text, keep a provenance list in the notices file.

## 4. Open questions

1. **Which opencode did the user try,** v1.19.x (TUI, long provider prompts, re-injected Plan reminder, doom-loop
   guard) or v2.2.x (minimal prompts, frozen instructions, output-limit recovery, no doom-loop guard)? It changes
   which behaviours they found "better".
2. **OpenHands 1.59 internals, all unverified:**
   - whether `UserRejectObservation.rejection_reason` reaches the model verbatim (§2.8 rec 2)
   - whether `agent.condenser` and its prompt can be set over REST
   - whether it loads AGENTS.md itself
   - the terminal-output truncation limits
   - how `max_iterations` stops are reported
   - how `/fork` behaves
3. **Gateway retry on truncation:** acceptable to bill the extra call silently, or show it in the composer meter as
   a separate `usage` line?
4. **Full auto with deny rules:** pay the per-action confirmation round-trip, or drop deny enforcement in Full auto?
5. **Custom primary agents:** a persona switch needs a new OpenHands conversation (persona is fixed at create). Is a
   "new conversation with summary" acceptable when switching to a custom primary mid-session, or should custom
   agents be subagent-only at first?
6. **Plan files:** opencode's experimental flow (a plan written to a markdown file, then approval) versus our
   structured `present_plan` card. Do we want a persisted plan file in `.everyai/plans/` so Build can re-read it after
   condensation?
