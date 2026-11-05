# Code workspace roadmap

Status as of 2026-11-04. Code is the coding half of EveryAI: one workspace for every coding agent. It runs on desktop;
phones, tablets and browsers drive a paired desktop through the remote relay. For the product as a whole, see
[ROADMAP.md](ROADMAP.md); for a picture of the pieces, [ARCHITECTURE.md](ARCHITECTURE.md). All paths below are under
`frontend/lib/features/code/`.

## 1. Architecture

### Drivers
- `drivers/driver.dart` defines `HarnessDriver`: info, capabilities, detection, models, and what a session can do
  (start, attach, send, steer, respond, set mode, rewind, adopt a session it didn't create). `driver_registry.dart`
  lists the agents; `driver_policy.dart` holds the fallbacks when an agent lacks a capability.
- One driver per protocol:
  - `everyai_driver.dart`: the EveryAI harness, in the app.
  - `claude/`: Claude Code over `claude -p` stream-json; approvals through a host permission tool.
  - `codex/`: `codex app-server` (JSON-RPC threads).
  - `opencode/`: `opencode serve` (HTTP + events).
  - `acp/`: any Agent Client Protocol agent, with a pinned profile per known agent (Antigravity `agy acp`, Gemini CLI,
    Cursor, Copilot, Qwen Code, Kiro, Kimi, Cline, goose, Mistral Vibe, Auggie, Factory Droid, Grok).
  - `terminal/`: CLIs with no protocol, driven through a pty (a fallback).
- Outside agents run on the user's own install and sign-in, in the session's worktree. A repo's own CLI config can't
  turn approvals off, and no tokens are written to disk. Claude Code and Google's agents need the user's consent
  (Settings → Code → Harnesses).
- `registry_install/`: "Add agent" from the ACP registry (pinned versions, checksums, safe unpacking, nothing run
  during install).

### The EveryAI harness
- `harness/everyai/`: the agent loop in the app, for any model on the user's key (through the backend gateway).
- Tools per model family (GPT gets `apply_patch`), parallel read-only steps, per-call approvals, retries with
  backoff, compaction that clears old tool output before summarising, output spill to `.everyai/spill/`, forks in
  their own worktrees, `run_script` (TypeScript in Deno, no permissions), a browser (CDP) and window screenshots.
- Effort levels Efficient and Thorough are EveryAI-only; Max, Ultra, Bug fix and Security review are shared workflows
  (below).

### The local MCP host
- `host/`: a loopback MCP server, one token per session (a fresh one each time a session opens; the old one
  is revoked).
- Tools: `ask_user_question`, `present_plan`, `memory`, `saved_plans`, `check` (targeted tests, detected per
  ecosystem, never a free command), `bug_check`, `diff_stats`, `goal_check`, `run_script` (without model calls when
  EveryAI isn't the lead), Max's `fork` / `check_forks` / `answer_fork` / `stop_fork`, and `run_workflow`.
- `check` and `bug_check` run commands, so they go through the session's approvals; the rest are trusted.

### The briefing
- `drivers/briefing/`: every outside session gets a short system note listing what EveryAI provides (tools, skills,
  workflows), plus the session's skills exported in the agent's own format. It shows as one collapsed row in the
  transcript, with the exact text sent.

### Workflows
- `workflows/`: an engine that runs `workflow.js` files in the bundled Deno sandbox with the workflow API (`agent`,
  `parallel`, `pipeline`, `phase`, schema-checked results). Each `agent()` call starts a session on any listed agent
  and model, in its own worktree, merged back through our diff. Caps on agents, turns and time; a journal for resume.
- Bundled: `assets/workflows/ultra.js` (research → implement → adversarial review → refix → integrate), `bugfix.js`,
  `security_review.js`. Project workflows in `.everyai/workflows/*.js` sit behind a digest trust gate.
- Every workflow is also an MCP prompt, so it appears as the agent's own command (`/mcp__everyai__ultra` in Claude
  Code). The workflow picker replaced the old tier picker; `PhaseFlow` is gone.

### Handoff and resume
- `handoff/`: when a lead's usage limit hits, "Your limit ran out, switch to:" lists the agents that can run, with a
  default for next time. The next agent gets the conversation in its own session format where possible
  (`handoff/native/`: Claude Code session file + `--resume`, Codex thread items, OpenCode session import), otherwise
  facts (plan, todos, touched files, git state) plus the transcript as a file. A turn cut off by the limit goes over
  as `<cut-turn>` and is finished, not redone. EveryAI makes no model call for any of this.
- `resume/`: New session lists a folder's earlier sessions from Claude Code, Codex, OpenCode and Gemini CLI (read-only
  from their own files), and resumes the chosen one on its own agent with its full history.

### Transcript, approvals and modes
- `domain/transcript.dart` folds every driver's events into one transcript, keeping each agent's own tool names,
  todos, plans and thinking. Each turn's work folds into one box; the final answer stays outside.
- Approvals: client tools go to their own UI; the safety floor (catastrophic commands) refuses on the EveryAI harness
  and warns as advice on outside agents; the user's deny rules; Plan refuses writes; read-only actions run; dangerous
  ones ask except in full auto; allow rules and remembered approvals; otherwise the mode decides.
- Modes: the EveryAI harness has Ask, Auto-edit, Plan and Full auto; outside agents show their own modes (Claude
  permission modes, Codex approval presets, OpenCode agents, ACP session modes), never a bypass mode.

### Git
- `git/`: a worktree and branch per session, a checkpoint per turn (hidden refs) with rewind for every agent, squash
  merge back, `/commit` and `/pr` (drafted without a model on outside leads).

### Remote relay
- Desktops register with `backend-exp` (`remote.zig`); devices pair by a single-use code or QR that the desktop
  approves. Frames are end-to-end encrypted (X25519, ChaCha20-Poly1305); the backend relays opaque bytes. The computer
  runs every session; devices mirror and act on it.

## 2. Status

Built and unit-tested: everything above (`flutter test`: about 1,500 tests).

Not yet run end to end:
- a real turn through every outside driver (Codex wasn't installed on the build machine; fixtures were recorded or
  derived from schemas)
- the limit picker and automatic handoff against a real usage limit
- a real "Add agent" registry install
- workflows on outside agents
- Windows and Linux on real machines

## 3. Next steps

In order (details in [ROADMAP.md](ROADMAP.md)):
1. A live pass over section 2.
2. Console layout: the right panel (session info, diff, files), the composer strip, the git button.
3. Easy setup and migration: desktop apps detected, one-step install and sign-in in our terminal, imports.
4. Local models and a light harness profile for small models.
5. Windows parity (shell, WSL, process cleanup).
6. The standalone package, then Lead Mode, then live terminal views.
7. The cheaper execution loop (runtime profiles, post-edit hooks, plan batches) and the OS sandbox.
