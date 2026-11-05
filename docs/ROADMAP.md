# EveryAI roadmap

Status as of 2026-10-30. The app is a prototype. It runs end to end on macOS against `backend-exp`. The other
platforms build, but most features have only been checked on macOS. This document covers where the product
stands, what we think will keep it ahead, and what comes next. The Code workspace has its own document,
[CODE_ROADMAP.md](CODE_ROADMAP.md).

## 1. Positioning

EveryAI is one app for every model. A user gets the full OpenRouter catalog (plus a native Anthropic route)
through one account and one wallet. They chat, search and research, build documents, decks, diagrams and
figures, and run a coding agent against their own repositories. All of this happens in an app that looks and
behaves like a native app on each platform.

Most competitors pick one of three things: a single model vendor (the vendor apps), a single job (search apps,
IDE agents), or a thin web wrapper over many models (aggregator sites). We aim to be the multi-model app that
does not feel like a wrapper. That means native UI, rich output the user can keep and edit, and a real coding
agent, all billed at a published markup over cost.

Pricing is cost × 1.15 on every paid model. Zero-cost models are free on every plan. Plans are Free, Pro and Max,
plus prepaid top-ups. Stripe runs in test mode and is mocked until keys arrive.

## 2. What is built

Roughly 250 commits on `everyai-revamp`. The main pieces:

**Backend (`backend-exp`, Zig 0.17 on Anole 0.4.1)**
- The `/v1` API: auth with rotating refresh tokens, the model catalog (OpenRouter, refreshed hourly, marked up),
  billing with quota, then wallet debits and a 402 preflight.
- `/v1/chat/stream` runs an SSE tool loop. It checks tool arguments against their schemas and returns typed errors
  (`tool_check.zig`). It recovers from cut-off replies (`truncation.zig`), passes reasoning back between
  tool-loop steps, and waits for tools that the app runs itself (`tool_wait.zig`).
- An OpenAI-compatible gateway (`/v1/chat/completions`) with per-user `sk-eai-` keys. The coding agent uses it,
  and so can any LiteLLM or OpenAI client.
- A native Anthropic adapter (`anthropic.zig`) behind the same upstream interface. Cost comes from catalog prices,
  including cache writes and the long-context tier.
- Prompt caching. The system prompt and tool JSON are compile-time constants. `cache_control` breakpoints are
  injected for Anthropic and Gemini models, with a 5 m TTL for chat and 1 h for the gateway. In a live agent
  run the second turn cost 69 µ$ instead of 1,113 µ$.
- Web search and paged `web_fetch` behind an SSRF-safe fetcher (`net/safe_fetch.zig`), with a per-turn source
  ledger that numbers each source once.
- Images through OpenRouter's image endpoint, Recraft vector output, and a one-round figure "Polish" pass
  (`polish.zig`).
- A routing table that sends side jobs (titles, follow-ups, compaction, critique, judge) to cheap models
  (`routing.zig`). Agent model tiers live in `agents.zig`.
- A remote relay (`remote.zig`) that pairs a desktop host with phones, tablets and browsers.

**App (`frontend`, Flutter 3.47, Riverpod 3, Drift)**
- Native UI per platform: Material, Cupertino, Fluent and macos_ui, behind adaptive wrappers, reskinned with
  the brand kit.
- Chat:
  - modes Chat, Search and Research
  - citations, follow-ups, retry and edit
  - attachments (images, PDFs, audio)
  - a token, cost and context meter
  - a thinking-effort control
  - slash commands and custom Markdown commands
- Rich output:
  - artifacts in a side panel, with versions, hand edits and in-place `edit_artifact`
  - SVG figures with style presets and stable ids, Mermaid drawn offline, Excalidraw drawings
  - charts, quizzes, flashcards, slides with PPTX export, and sandboxed HTML widgets
  - Markdown, PDF and Word downloads that embed real diagrams and equations
- Local-first memory: two capped notes, frozen per chat so the cache holds, plus a `search_chats` tool over the
  on-device full-text index. Chat history stays in Drift on the device.
- Skills in Chat and Code (the open Agent Skills format), with an import validator and a trust gate. Four
  built-in skills steer slides, documents, diagrams and vector art.
- Code: the coding workspace, described in [CODE_ROADMAP.md](CODE_ROADMAP.md).

**Tooling and evals**
- A headless agent-eval driver (`frontend/tool/agent_eval/`) and a 20-prompt SVG eval with a render gate and a
  vision judge (`frontend/tool/svg_eval/`, not yet run live).

## 3. The moat

No single feature here is unique. What is hard to copy is having all of them in one product, with the cost
structure to price it.

1. **A multi-model gateway that saves money on caching.** Every request goes through our backend, which builds
   prompts so they stay cacheable: constant prefixes, fixed tool order, volatile content last, and breakpoints
   injected where the provider needs them. The savings are real (94% on a second agent turn) and show up in the
   ledger as cached and cache-write tokens. The markup is fixed and published, so cheaper upstream calls either
   lower the user's cost or widen our margin. The same gateway serves Chat, Code, Ultra and any outside
   OpenAI-compatible tool, which makes one wallet a reason to stay.
2. **Native-feel apps on six platforms from one codebase.** macOS, iOS, Android, Windows, Linux and web, each
   using its own design language. Most multi-model products are web pages or Electron shells. Native menus,
   popovers, vibrancy and type scales cost a lot to retrofit.
3. **Code with our own control layer.** The agent loop comes from OpenHands (MIT), but every decision about
   actions is ours:
   - a permission policy with a hardline floor that holds even in Full auto
   - per-session git worktrees and checkpoints with rewind
   - question cards and plan approval inside the tool call
   - subagents as child conversations, plus an agent library
   - Ultra, a planned multi-agent run with budget caps
   - a remote host so a phone can drive a desktop session
   The harness is behind an interface, so other agent loops can be added later without losing this layer.
4. **Artifacts and vector art the user can keep.** Output is a file the user can open, edit and download, not
   text in a bubble: versioned documents, slides to PPTX, diagrams and equations rendered into PDF and Word,
   SVG figures with stable ids that the model can edit in place, and Excalidraw drawings. Render checks run in
   the app and send errors back to the model, so a broken diagram gets fixed instead of shown.
5. **Local-first memory and history.** Conversations, memory notes and the search index stay on the device. That
   is a privacy argument, and it also means our backend stores very little user content. Memory is frozen per
   chat so it does not break the cache.

## 4. What's next

These horizons are rough and assume one developer with agent help.

### Now to end of 2026: make what exists trustworthy
- Click through every feature built in the 2026-10-30 pass on macOS. Most items in TODO.md are marked "not
  clicked through" or "not tried live".
- Run the new Code eval once the owner supplies the objective. It grades results, worktree use, observability,
  and questions and plans.
- Code track 7: a scratch folder per session, asking before writes outside the worktree, a project memory file,
  approved plans saved to disk, recap lines and auto-compact at 80%.
- Remote coding: run against the live relay and on a real phone and web build, and give remote sessions
  worktrees and project context.
- Usage tracker in Settings, using group-by aggregates on `/v1/usage`.
- Attachments: paste from the clipboard, a server-side modality guard, blob GC, and stop resending large images.
- Adopt Anole's SSE parser and migrations once those PRs merge, and delete the local copies.

### Q1 2027: ship to real users
- Stripe live keys, Google sign-in, macOS signing and notarization, and a license choice.
- A real deployment of `backend-exp`, with PostgreSQL and more than one instance. The relay state is in-process
  today, so it needs a shared store or sticky routing first.
- Windows and Linux: bundle the agent-server and set up CI runners.
- Track 2 and 3 backend gaps (skipped this pass by owner decision):
  - link resvg for server-side SVG validation and rasterizing
  - a Zig MCP client for remote connectors
  - an OAuth 2.1 token vault
- First connectors (GitHub, Google Workspace, Notion), with per-chat toggles and approval for write tools.

### Q2 2027 and later: widen the moat
- More harnesses behind the Code interface, and native OpenAI and Google adapters on the backend.
- Run untrusted repos in a sandbox, using OpenHands' Docker workspace.
- A Hermes-style skill review after each session (opt-in and on the meter).
- A desktop helper process for local stdio MCP servers and render jobs.
- Video generation, once pricing is decided.
- A macOS App Store variant: sandboxed, without Code or with a helper.

## 5. Risks

- **Upstream dependence.** OpenRouter carries most traffic. An outage, price change or terms change hits every
  feature. The native Anthropic adapter is a first hedge; OpenAI and Google adapters would widen it.
- **Margin.** A 15% markup is thin. If caching savings are passed to users, margin depends on volume. Free models
  cost us infrastructure but earn nothing.
- **OpenHands coupling.** We pin agent-server 1.59.0 and work around its bugs (its own `task`/`delegate` tools
  crash; there is no elicitation; the condenser can't be customized). An upgrade can break the protocol. The
  harness interface limits the damage but does not remove it.
- **The agent runs as the user.** The permission policy is defence in depth over shell strings, not a sandbox.
  A clever command or a hostile repository can still do harm. Docker workspaces are the real fix and are not
  built.
- **Verification debt.** Much of the 2026-10-30 pass passed analyze and unit tests but was never used live.
  Prompt and tool-description changes are meant to be eval-gated, and that gate has barely run.
- **Six platforms, one team.** Native UI per platform multiplies UI work and test surface. Linux and Windows
  have no CI.
- **Security leftovers.** A Supabase DB password and Google API keys are in pushed history and must be rotated.
  `DEV_AUTH` on a LAN host exposes the dev account. Relay tokens can appear in access logs when sent as a query
  parameter.

## 6. Owner decisions pending

From TODO.md "Owner input required":
- The new Code eval objective.
- Final Ultra defaults. The build pass used 16 concurrent and 150 total agents, $25 and 2 h per run, Opus
  orchestrating, Max plan only.
- Whether to run a skill review after each session, and its budget.
- Video pricing.
- Rotating the leaked secrets.
- Google Sign-In and Firebase config for `dev.alidirect.everyai`, and merging the three Google projects.
- Stripe test keys.
- A license (today `LICENCE.md` says all rights reserved).
- The macOS signing team.

Also open, not yet raised with the owner:
- Whether caching savings go to users (lower bills) or stay as margin.
- Where `backend-exp` is hosted.
