# EveryAI roadmap

Status as of 2026-11-04: pre-alpha dev build `0.1.0-dev-nonsigned`. macOS is the daily driver; Windows and Linux
build in CI but haven't been tested on real machines. The Code workspace's internals are in
[CODE_ROADMAP.md](CODE_ROADMAP.md).

## 1. Positioning

**EveryAI is a coding harness and orchestrator for every coding agent.** Native agents like Claude Code, Codex and
OpenCode are already good, and millions of people use them. EveryAI doesn't replace them; it gives them one workspace
and adds what they don't have:

1. **The harness and orchestrator are the product.** Our own agent (the EveryAI harness) runs any model, and our
   workflows, checks, rewind and tools run in every agent. Model access (OpenRouter or Anthropic) is plumbing, not the
   product.
2. **BYOK.** Users bring their own API keys and their own subscriptions. EveryAI holds no provider keys in the dev
   build and spends nothing on sessions it doesn't lead.
3. **Local AI.** Local models (Ollama, LM Studio, llama.cpp) get the same harness and tools as online ones. Coming
   next.
4. **What exists works.** Chat with artifacts, Code with approvals, worktrees and checkpoints, remote control, skills
   and MCP are built and run on macOS (pre-alpha:
   expect bugs).
5. **Magical integration.** Outside agents feel native (their slash commands, modes and tool names), sessions resume
   across agents, a usage limit hands off without losing a step, and one-step setup brings in agents the user already
   has.

## 2. What is built

- **Every agent in one workspace:** drivers for Claude Code, Codex, OpenCode, ACP agents (Antigravity, Gemini CLI,
  Cursor, Copilot, Qwen Code, Kiro, Kimi, Cline, goose, Mistral Vibe, Auggie, Factory Droid, Grok, any ACP agent) and
  terminal-only CLIs; installed-agent detection and "Add agent" from the ACP registry.
- **Native feel:** each agent's own slash commands and modes, its own words in the transcript, our safety floor as
  advice for outside agents (a hard floor for the EveryAI harness).
- **Increments for every agent, at no cost to us:** a local MCP host with `check`, `bug_check`, `diff_stats`,
  `goal_check`, `run_script`, memory and saved plans; checkpoints and rewind; workflows (Ultra, Bug fix, Security
  review) as `workflow.js` run in Deno and served as MCP prompts; Max as an approach skill with fork tools.
- **Continuity:** handoff on a usage limit (native import into the next agent's session format, or facts plus the
  transcript file), a default handoff target, and resuming any agent's earlier session from New session.
- **The EveryAI harness:** any model on the user's key, per-family tools, approvals, compaction, forks in worktrees,
  a browser and screenshots for checking its own work.
- **Chat:** modes (Chat, Search, Research, Learn, Summarise), artifacts with versions and downloads, slides, charts,
  diagrams, quizzes, memory and history on the device.
- **Remote control:** phones, tablets and the web pair with the desktop over an end-to-end encrypted relay.
- **Infrastructure:** the dev backend on Anole 0.5.1 with its own TLS and rate limiting; Windows and Linux builds from
  CI; a first-launch tour.

## 3. What's next

In order:

1. **Console layout:** the session screen reworked around a right panel (session info with context, usage and
   running work; diff; files) and a composer strip for the agent, workflows, skills and MCP.
2. **Easy setup and migration:** desktop apps detected (Claude, Cursor, Antigravity, Codex), the agent's official
   installer and its own sign-in run in EveryAI's terminal, and the user's MCP servers, rules and sessions brought over
   with a yes.
3. **Local models:** Ollama, LM Studio and llama.cpp called from the app, a lighter harness profile for small models,
   and an offline mode.
4. **Windows parity:** a Windows shell for the EveryAI harness, WSL as a per-project environment, process cleanup, and
   a test pass on real machines.
5. **The standalone package:** the same MCP server, skills and workflows as a plugin for Claude Code, Codex and
   OpenCode in the user's own terminal.
6. **Lead Mode:** the EveryAI harness leads and delegates batches of work to other agents, each in its own worktree,
   with a check gating every merge.
7. **Live terminal views:** each agent's real terminal UI beside the transcript where it can attach.
8. **Releases:** the Microsoft Store (signed by the Store; winget installs from it), Flathub, and a notarized macOS
   DMG with a Homebrew tap, from the first alpha on.

Also planned: an OS sandbox for shell commands (Seatbelt, bubblewrap), headless mode and user hooks, LSP diagnostics,
and a cheaper execution loop (runtime profiles, targeted tests, batched edits).

## 4. Risks

- **Vendor terms.** Running a user's own logged-in CLI is allowed for some vendors and unclear for others. Claude Code
  and Google's agents sit behind a consent setting until their terms are checked, and EveryAI never reuses an agent's
  login tokens.
- **Moving targets.** Each agent's protocol and session format can change with any release. Drivers are pinned to
  profiles and tested against recorded fixtures, but they need upkeep.
- **Verification debt.** Much of the multi-agent work passed analyze and unit tests but hasn't run end to end against
  every real agent.
- **The agent runs as the user.** Approvals and the safety floor are defence in depth over shell strings, not a
  sandbox, until the OS sandbox lands.
- **Six platforms, one small team.** Native UI per platform multiplies UI work and test surface; Windows and Linux
  haven't been tested on real machines.
