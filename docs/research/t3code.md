# T3 Code vs EveryAI Code (2026-10-31)

Source: `github.com/pingdotgg/t3code` @ cbd43b63 (2026-11-01), MIT. Read: README, AGENTS.md, `docs/` (user,
internals, orchestration-v2), `apps/server/src/{mcp,provider,scheduledTasks,cloud}`,
`packages/provider-core/src/server/orchestrationInstructions.ts`. Nothing was run.

## What it is

A self-described "agent harness control surface" (their FAQ: "Is T3 Code a harness? No."). A Node/Effect
WebSocket server (`npx t3`, or bundled into the Electron app) drives the user's **installed, logged-in** agents
and serves web (local + app.t3.codes), desktop (Electron) and mobile (React Native) clients.

Providers, each behind an adapter in `packages/provider-*`:
- Codex: `codex app-server` (JSON-RPC), the richest protocol and the model for their orchestration v2
- Claude: Anthropic Agent SDK with the user's Claude Code login (FAQ: drains the 5 h limit faster than the CLI)
- Cursor: `@cursor/sdk`; OpenCode 1.x/2.x servers; Pi in RPC mode; Grok, Antigravity, Muse, fx; any ACP Registry agent

## Does it inject its own harness?

**No, it injects a thin layer.** The agent loop, tools, permissions enforcement, compaction and system prompt
stay the provider's. T3 adds:
1. **An MCP server `t3-code`** per provider session (`http://127.0.0.1:<port>/mcp`, bearer token scoped to
   environment + thread + provider session, idle expiry, revoked on release). Injected via Codex `-c
   mcp_servers…`, Claude SDK `mcpServers` + `allowedTools: mcp__t3-code__*`, ACP `session/new.mcpServers`, a
   generated Pi extension. Tools: `delegate_task` / `task_status` / `task_cancel` (subagents on **any** provider,
   optional worktree), `t3_thread_*` / `create_threads`, PR link/watch, `schedule_task`, `request_secret`,
   `html_preview`/`html_render`, `preview_*` (browser), `device_*` (iOS sim / Android emulator),
   `t3_environment_link(s)` (act on another machine).
2. **~11 KB of instructions** (`orchestrationInstructions.ts`, `runtimeInstructions.ts`): when to use native
   subagents vs `delegate_task`, thread etiquette, visuals, secrets. On Codex this goes into `additionalContext`
   entries capped at 4 KB each.
3. **Normalisation**: provider events → their own event-sourced execution graph (runs, execution nodes, provider
   threads), so every provider looks the same in the UI. Missing capabilities degrade by policy (no native steer →
   cancel-and-restart; no native fork → portable context handoff; no native subagents → T3 child threads).

So the user's guess is half right: it wraps existing harnesses, but it does **not** replace their brains the way
our Max/Ultra and modes do. Permission modes are mapped onto each provider's own ("Providers enforce permissions
differently"; Auto = the provider's auto-review; OpenCode/Antigravity fall back to asking).

## What they have that we don't

Ranked by how much it matters to us.

1. **Bring your own subscription.** Claude Max / ChatGPT / Cursor plans pay for the tokens. That's their whole
   pitch, plus "every harness feels the same". We only run our harness on API-priced tokens (credits or BYOK
   keys).
2. **Cross-provider delegation and switching.** A Claude thread can `delegate_task` to Codex/Cursor. Switching
   providers mid-thread resumes the old provider thread with a **delta handoff summary** (explicit, stored
   `ContextHandoff` artifacts with coverage per provider thread; full summary when stale). See
   `docs/orchestration-v2/provider-switching-and-context.md`. Our `switch_llm` changes the model inside our own
   loop and has no handoff concept, since we don't need one.
3. **Outside agents over MCP** (`docs/user/outside-agents.md`): Claude Code in a terminal, ChatGPT or a bot can
   list projects, start threads and message them, with per-agent scopes.
4. **A headless host and remote infrastructure.** `t3 up` / `t3 service install` (launchd/systemd), T3 Connect
   (managed cloudflared tunnels, 3 machines free), LAN pairing, Tailscale, the hosted web client, multi-environment
   (one client drives several machines; agents act across linked machines). Our host has to be the Flutter desktop
   app, which must be running.
5. **Mobile push**: notifications for done/failed/needs-approval/asks-input, iOS Live Activities, Android ongoing
   activity. We have only local OS notifications on the desktop.
6. **Scheduled tasks and webhooks** that start agent runs (interval/cron, verified webhooks, templates, dedupe).
7. **Source control depth**: GitHub, GitLab, Forgejo/Gitea, Bitbucket, Azure DevOps and GitCafe; a PR view; PR
   links and stacks per thread; a PR sync reactor that notices `gh pr merge` run by the agent; server-side
   auto-settle of idle/merged threads; a review service; per-turn diffs that exclude files git brought in.
8. **Checkpoints as hidden git refs** (no commits on the user's branch), coordinated with provider conversation
   rollback; providers that can't roll back refuse first. (We already have this: per-session worktrees and
   `refs/everyai/<slug>/turn-<n>` snapshots in `git/git_service_io.dart`. Their extra is refusing a file rewind
   when the provider can't rewind its conversation.)
9. **Event-sourced server**: commands → events + projections + outbox in one SQLite transaction, with side
   effects after commit and idempotent receipts. Replay-backed tests against recorded provider transports. We
   keep JSON in Preferences plus `state.json`.
10. **Devices panel**: a live iOS Simulator or Android Emulator beside the thread, which agents drive with
    `device_*` and the `agent-device` CLI. **SnapShots**: window capture plus its **accessibility tree** (controls,
    text, positions). Our `screenshot` sends pixels only.
11. **Browser panel**: importing cookies from Chrome/Safari etc., T3 as the macOS default browser (a link opens a
    thread about the page), `preview_act`/`preview_snapshot`.
12. Small but nice:
    - guest links (a teammate follows a thread and asks questions that wait for your OK)
    - prompt links (one-click draft, never auto-runs)
    - "Triage an issue" playbook
    - pastes ≥32 KiB become an attachment
    - files attached to question answers
    - MCP Apps rendered inline
    - multi-account per provider (separate config dirs)
    - `request_secret` with 1Password and file delivery
    - command palette for everything
    - themes
    - cross-provider usage with API-equivalent cost
13. **Distribution and process**: brew/winget/scoop/AUR/nix/deb, App Store and Play; self-update of servers and
    providers through the owning installer; evals (`evals/test-signal`, `mcp-tool-use`, `thread-titles`); custom
    lint rules that ban sleeps/polling in tests; a "hit every surface" checklist in AGENTS.md.

## Where we're ahead

1. **We own the harness, so behaviour is ours to shape.** T3 can only use what each provider exposes. We have:
   - Ultra: the `ultra_plan` engine with phases, parallel/pipeline, a worktree per writing step, schema retry,
     verify, critic, caps and journal resume
   - real mode semantics: Plan rejects writes, Ask is read-free, enforced by **our** permission engine (floor,
     quote-aware shell classifier, dangerous classifier, once/session/always, per-call approvals, risk labels)
   - doom-loop and repeat guards
   - compaction that re-injects the plan, todos and files
   - model-family rules (V4A `apply_patch` for GPT)
   - `run_script` (codemode/RLM in sandboxed Deno)
   - the `decide` aux
   - fork questions routed to the orchestrator
   - retry UX with Retry-After
   T3's orchestration is mostly "please call `delegate_task`" in prose.
2. **Any model.** Through OpenRouter (Gemini, Kimi, DeepSeek, free models…) with our own cache breakpoints, and
   Auto routing. T3 is limited to models that have a CLI/SDK agent, and caching is whatever the provider does.
3. **Chat as a product**: modes (Search/Research with parallel researchers, Learn, Summarise), artifacts with
   versions and in-place edits, quiz/flashcards/slides→PPTX, PDF/DOCX export, image generation, local memory,
   skills, `summarise_parts`. T3 Code does code only (T3 Chat is a separate product). Their `html_preview` visual
   replies are a small subset of our artifacts.
4. **E2E-encrypted remote.** Our relay sees only opaque X25519/ChaCha20 frames. T3 Connect routes over Cloudflare
   tunnels (TLS to their edge; no E2E layer documented that I found). We also mirror one session to several
   devices that drive it together.
5. **No dependency on vendor ToS or SDK quirks.** T3's Claude path rides the Agent SDK with consumer logins (their
   own FAQ notes the 5 h drain bug), and every provider update can break an adapter (hence their installer and
   lease machinery).
6. **A business model**: credits ×1.15, plans, BYOK. T3 Code earns nothing directly (Connect limits nudge T3
   Chat).
7. **Native UI** on 6 platforms from one Flutter codebase. They maintain React web + Electron + React Native.

## What to copy (MIT: code is copyable with a THIRD_PARTY_NOTICES entry; rewrite prompts)

| # | Item | Why | Size |
|---|------|-----|------|
| 1 | **External-harness providers**: an ACP client first (covers Grok, Antigravity, Gemini CLI, the registry), then Claude Agent SDK / `codex app-server` | BYO subscription is the single biggest adoption lever. Inject *our* MCP (ask_user_question, present_plan, ultra/fork tools, memory) the way T3 injects `t3-code`. Our transcript already decodes OpenHands-shaped events. Strategic call for the user: we just removed OpenHands. | L |
| 2 | **EveryAI as an MCP server** for outside agents (list/start/message sessions, scoped tokens) | Cheap, and makes us the hub | M |
| 4 | **Headless host daemon** + push notifications (APNs/FCM via backend-exp) for approvals/questions/done | Remote is only useful if the phone pings you | M–L |
| 5 | **Scheduled tasks + webhooks** starting Code sessions | Pairs with /morning, /goal | M |
| 6 | **Handoff artifact on model/family switch** (delta summary, stored, visible) | We already compact; make switches explicit | S |
| 7 | **Accessibility tree with screenshots** (AX API via JXA on macOS) | Cheaper, more precise than pixels for agents | S–M |
| 8 | Paste ≥32 KiB → attachment; prompt links (`everyai://prompt?…`, never auto-sends); attachments in question answers | Quick wins | S |
| 9 | PR linking per session + sync after the agent runs `gh pr merge`; per-turn diff excluding pulled files | Code polish | M |
| 10 | Eval patterns: `test-signal` (does the agent run tests), MCP tool-use grading; lint rules against sleeps in tests | When the eval gate returns | S |

Skip: the Cloudflare tunnel (our relay is better), the Electron/RN stack, multi-account per CLI, default-browser
mode, guest links (later, maybe).
