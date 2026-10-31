# Code workspace roadmap

Status as of 2026-10-30. Code is the coding-agent half of EveryAI. It runs on desktop. Phones, tablets and
browsers can drive a paired desktop through the remote relay. This document covers how Code is built, what
works, and what comes next. For the product as a whole, see [ROADMAP.md](ROADMAP.md).

## 1. Architecture

```
 Flutter app (desktop)                                     backend-exp
 ┌──────────────────────────────────────────────┐          ┌─────────────────────────┐
 │ Session view: transcript, composer, top bar, │          │ /v1/chat/completions    │
 │ panes (Changes, Terminal, Processes, Preview)│          │ (gateway, sk-eai- key,  │
 │                   │                          │          │  cache breakpoints,     │
 │ CodeSessionController ── permission policy   │          │  billing per session)   │
 │                   │                          │          └───────────▲─────────────┘
 │ Harness interface ── EveryAI harness ────────┼──────────────────────┘ LLM calls
 │                    └ FakeHarness (demo)      │
 │ Git service: worktree per session, checkpoints│
 └──────────────────────────────────────────────┘
```

### Sidecar (removed)
- The bundled OpenHands agent-server was removed on 2026-10-31: the EveryAI harness (`harness/everyai/`, the agent
  loop in the app) is the only Code harness. Sessions stored with `harness: openHands` show a notice instead of
  reopening. The macOS app bundles Deno instead (`Contents/Resources/deno`, `macos/scripts/bundle_deno.sh`) for
  `run_script`.
- The harness's LLM provider is our gateway. The base URL is `API_BASE_URL/v1`, and the key is
  a per-user `sk-eai-` key kept in secure storage and re-minted on a 401. Usage is attributed through
  `X-EveryAI-Session` and read back from `/v1/usage/session/:id` for the composer meter.

### Harness
- `harness/harness.dart` defines `Harness` (start, attach, statuses) and `HarnessSession` (send, interrupt, pause,
  resume, respond, setMode, switchLlm, rewindTo, close), plus `SessionSpec`.
- The EveryAI harness runs the loop, tools and permissions in the app and keeps sessions under app support.
- `FakeHarness` plays a scripted demo session (`demo://counter-app`) for UI work without a model.
- `harness/events.dart` turns OpenHands-shaped `kind`s (which the EveryAI harness emits) into a sealed
  `HarnessEvent` type.

### Transcript
- `domain/transcript.dart` folds events into items:
  - user turns, agent text, explore groups (consecutive read-only steps)
  - steps, subagent cards, plan items
  - question cards, plan proposals, notices
- Tool rows show a label, a preview, progress, elapsed time and highlighted commands, paths and diffs.
- Output over 2,000 lines or 50 KB is spilled to `.everyai/spill/` and shown as a preview.
- `present_files` gives deliverable cards for the files the agent finished with.

### Permissions
OpenHands confirms every action and the app decides (`domain/permissions.dart`, 7d2c7f9). The order:
1. Client tools go to their own UI.
2. The hardline floor blocks a short list of catastrophic commands in every mode, Full auto included.
3. The user's `deny` rules.
4. Plan mode refuses anything that is not read-only.
5. Read-only actions run. `shell_readonly.dart` is a quote-aware classifier with per-segment allowlists.
6. Dangerous actions always ask, except in Full auto.
7. `allow` rules and approvals remembered for the session. These apply only to simple commands, never to
   chained ones.
8. Otherwise the mode decides.

The modes are Ask, Auto-edit, Plan and Full auto. The current mode is restated on every message, and leaving
Plan is announced. Denials use fixed wording that tells the agent not to retry by another route. A cloned
repository cannot approve its own commands or read files outside itself (4794609).

This is defence in depth over shell strings, not a sandbox. The agent runs as the user.

### Questions and plans
- `ask_user_question` (1–4 questions; radio or checkboxes; an "Other" field) and `present_plan` are OpenHands
  client tools.
- Answers go back inside the held tool call (`respond_to_confirmation` with the answers as the reason, then
  `/run`), so the agent keeps its turn (4231e62). The old path, sending the answers as a user message, is still
  available behind `CODE_HELD_ANSWERS=false`.

### Git
- Each session gets its own worktree and branch under app support `worktrees/` (`git/git_service_io.dart`).
  Hooks strip agent-credit trailers from commits.
- Each turn makes a checkpoint. Rewind restores the files and moves the conversation back with OpenHands
  `/navigate` (208a86e).
- Sessions merge back with a squash merge. `/commit` and `/pr` draft the commit message and the PR (through `gh`
  if it is signed in).

### Context and settings
- The app reads `AGENTS.md`/`CLAUDE.md` itself, walking up from the worktree, with a size cap and an injection
  scan. Nested files are appended when the agent first touches their folder (5504d34).
- Settings are layered (global, project, session) with a raw JSON editor, a system prompt per layer, and a
  per-session budget (823e8f1).
- Code also uses:
  - MCP servers (via `mcp_config`, with a consent dialog for stdio commands)
  - Agent Skills (sent as `agent_context.skills`)
  - an agent library (`.everyai/agents/<name>.md`, built-ins in `assets/agents/`)
- Other safeguards:
  - the doom-loop guard asks the user after three identical calls
  - compaction prunes old tool output, then summarizes with Haiku 5.5 into a new conversation
  - Stop kills every process the session left running

### Subagents
- `run_subagent` is a client tool. Each call spawns a child OpenHands conversation, depth 1, with its own context
  and permissions; the agent can pick a library agent for it (2c3010d, 2bb17d1). OpenHands' own `task` and
  `delegate` crash in 1.59.0, which is why we built our own.
- The child shows as a nested card, and its result comes back as the tool result.

### Ultra
- Ultra is a planned multi-agent run (`features/code/ultra/`, 6210b27, 6617a8a). An orchestrator writes a plan
  through the `ultra_plan` tool: phases, parallel and pipeline steps, structured results, verify passes and a
  completeness critic that can add one gap phase.
- Each step is a child conversation. A step that writes files gets its own worktree, merged back with
  `--no-ff`.
- Caps on agents, concurrency, dollars and wall time are checked against the wallet. Build-pass defaults: 16
  concurrent and 150 total agents, $25 and 2 h, Max plan only. All of a run's spend counts against its cap
  (017b00e). Stop also ends the steps' leftover processes.
- A journal on disk makes runs resumable. The UI is a toggle and caps popover in the top bar, plus a live
  progress tree (phase, then agent cards with status, cost, elapsed time and Open).

### Remote relay
- A desktop host registers with `backend-exp` (`remote.zig`) and keeps a WebSocket open. Devices pair by a
  single-use code or QR that the host must approve (614d3d0, be783ab).
- Each connection runs a handshake: static and ephemeral X25519, HKDF-SHA256, and a ChaCha20-Poly1305 key per
  direction with replay counters. The backend relays only opaque frames.
- On the host, `host_bridge.dart` exposes only the conversation API, event sockets and the project list to the
  sidecar. A conversation must start inside a host project.
- Clients use `RelayHarness`. Mobile and web show Code once a host is approved. Signing out stops hosting and
  drops pairings (0a0a7bf).

## 2. Status

Built and unit-tested: everything in section 1.

Run live against a model, on Haiku 5.5:
- the sidecar with the gateway
- Plan and Ask scenarios with question cards
- held answers
- restart recovery
- compaction recall

Not yet run live, or not clicked through in the macOS app:
- permissions round-trip time in Full auto
- `switch_llm`
- rewind after a live agent turn
- MCP servers against a real agent-server
- skills via `invoke_skill`
- subagents started with a library agent
- Ultra end to end
- the remote relay on a real phone or web build
- most panes and settings screens

Known gaps:
- Remote sessions run in the project folder itself. They get no worktree, panes, checkpoints, project context,
  skills or MCP.
- Ultra:
  - the toggle and caps are not persisted
  - the answer reaches the parent only through the hand-off button
  - the planning stage is not journaled
  - the Max gate is enforced in the app only
- The per-session budget stop runs only while the session view is open. Full auto sessions that are not open
  wait for approval.
- Notifications use osascript or notify-send, so Windows gets none.
- Windows and Linux do not bundle the agent-server yet.

## 3. Next steps

In order:
1. **The new Code eval**, once the owner supplies the objective. It grades results, worktree use, observability,
   and questions and plans. The Futoshiki grader stays as an asset.
2. **Track 7 from TODO.md:**
   - a `.everyai/scratch/` folder per session
   - asking before writes outside the worktree and scratch, even in Full auto
   - a project memory file the agent curates
   - approved plans saved to `.everyai/plans/`
   - faded recap lines
   - auto-compact at 80% of the context window, with settings in the top bar
3. **A live pass** over everything listed as not run live in section 2, starting with Ultra and the relay.
4. **Remote parity:** worktrees, context, skills and MCP for sessions started from a device, and those sessions
   in the host's session list.
5. **Persistence:** Ultra toggle and caps, goals and aside cards across restarts. A background budget check that
   does not need the session view.
6. **Permissions UI:** a rules screen over `codePermissionsProvider`, and an approval timeout.
7. **Platforms:** bundle for Windows and Linux; notarize the macOS build with the hardened runtime.
8. **Later:**
   - Docker workspaces for untrusted repos
   - more harnesses behind the interface
   - a per-child model tier and worktree for `run_subagent`
   - an App Store variant without Code
