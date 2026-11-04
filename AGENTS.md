# AGENTS.md — EveryAI working notes (tracked; a local `CLAUDE.md` symlink to this stays gitignored)

Context for the next agent. Keep it current: update the **Progress log** and
**Next steps** whenever you finish a step. Plans under `~/.claude/plans/` and the TODO*.md files are the
owner's local notes (gitignored); the task board is the GitHub Project.

## Rules (from the user — do not break)
- **Commits:** author as your own git identity (the owner's agents commit as
  `xuckless` with the GitHub noreply address). **No Claude/AI identifiers**
  anywhere in commits or PRs. That means no Co-Authored-By, no "Generated with",
  no session links, and Claude is never added as a collaborator.
- **Branch:** `main` is PR-only and needs the owner's review. The owner works on
  `everyai-revamp`; collaborators branch off `main` and open a PR. One commit per
  finished phase or step.
- **Secrets:** never commit `.env` or keys. Use `.env.example`. The OpenRouter
  key (and an Anthropic key) live in the **repo-root `.env`**. Don't scrub
  history; secrets get untracked instead.
- **Anole gaps:** build the tooling locally in backend-exp first, then open a
  PR to `xuckless/anole` with a neutral description. **Ask the user before
  tackling any new gap** beyond the SSE client and migrations.
- **Prototype:** production guardrails are not required yet. Large passes run
  best-effort: write blockers to TODO.md and move on.
- **Eval gate:** every prompt or tool-description change states its reason
  (in the commit body) and must not regress the live Code scenarios
  (`frontend/tool/agent_eval/`) or the SVG set.
  **Suspended during the 2026-10-30 prototype build pass (user):** skip prompt
  testing and live eval gates; the user will test extensively later. An agent
  asked to run an "EVAL GATE" returns at once with status `blocked` and
  summary "skipped by user (prototype phase)". Avoid live model calls unless
  an item cannot be built without one (e.g. a protocol spike).
- **Copying:** copy permissive code (MIT/Apache/BSD) only, with an entry in
  `THIRD_PARTY_NOTICES.md`; prompts are always rewritten in our own words.
  Never copy Anthropic's proprietary docx/pdf/pptx/xlsx skills. Don't copy code
  from Open WebUI, LobeChat, Cherry Studio or Dify, and don't depend on the
  Remotion or tldraw SDKs.
- **The user commits too** (e.g. README edits during a build pass). New commits or a
  brief `.git/index.lock` from them are expected: retry, keep going, and never
  touch or revert their files. The user may also add items to TODO.md mid-run:
  re-read before editing it, change only your own item's line, and don't pick up
  the new items.
- **Long runs:** kill stray processes (servers, zig, flutter) and watch disk
  use, since `.zig-cache` grows without bound. Clear it when large.

## Monorepo map
- `frontend/`: the Flutter app ("EveryAI"), Flutter 3.47.9, Riverpod 3, Drift.
  - Native UI per platform: `material_ui` (m), `cupertino_ui` (c),
    `fluent_ui` (f), `macos_ui` (mac), with adaptive wrappers in
    `lib/core/ui/adaptive*.dart`.
  - Features live in `lib/features/<feature>/{data,domain,ui}` plus a
    `*_providers.dart`.
  - Chat: `features/chat/` (controller `chat_providers.dart`, transport
    `data/chat_transport.dart`, markdown `ui/chat_markdown.dart`).
  - Models: `features/models/` (catalog, library, shop).
  - Sidebar and shell: `features/history/ui/sidebar.dart`, `app/shell.dart`.
  - macOS vibrancy comes from `macos_window_utils` `TransparentMacOSSidebar`;
    the rail is 92px on macOS so the traffic lights fit inside it.
  - Tests: `flutter test` (app) and `packages/*` tests. Screenshots go through
    the seeded demo DB under the macOS container.
- `backend/`: the legacy FastAPI app (uv). **Frozen**; being replaced by backend-exp.
- `backend-exp/`: the new backend in **Zig 0.17.0 on Anole** (the `xuckless/anole`
  tag pinned in `build.zig.zon`). See `backend-exp/README.md`.
  - `zig build run` serves `:8080` with docs at `/docs`.
  - `zig build test` runs 8 unit and 8 integration tests (in-memory routes
    against `openrouter.Fake`).
  - Layout:
    - `src/main.zig`: App state, routes, `prepare` (migrate + dev seed)
    - `config.zig`: env-driven Config; reads `.env` then `../.env`
    - `auth.zig`: JWT (15 min) plus rotating refresh tokens (60 days) and
      `sk-eai-` gateway keys. Middleware `Authenticate{keys}`. With
      `DEV_AUTH=true`, anonymous requests act as `dev-user` (pro plan, $20).
    - `billing.zig`: plans free/pro/max, quota → wallet debit, 402 preflight,
      Stripe checkout (mocked without keys), webhook.
    - `models.zig`: OpenRouter catalog refreshed hourly, marked up ×1.15,
      `:batch` excluded, featured defaults.
    - `chat.zig`: `/v1/chat/stream`, the SSE tool loop.
    - `tools.zig`: the constant system prompt and tool schemas (cache-stable).
    - `gateway.zig`: OpenAI-compatible `/v1/chat/completions` for
      OpenHands/LiteLLM.
    - `images.zig`: `/v1/images`.
    - `openrouter.zig`: upstream client, stream parsing, Fake.
    - SSE parsing uses `anole.sse.Parser`; migrations use `anole.db.migrate` with the list in `migrations.zig` (Anole 0.4.1).
- `docs/`: `ROADMAP.md` (product and moat) and `CODE_ROADMAP.md` (Code architecture and next steps); keep them current.

## /v1 contract (backend-exp ⇄ app)
- **Auth:**
  - `POST /v1/auth/signup|login` takes `{name?, email, password}` and returns
    `{access_token, refresh_token, token_type, expires_in, user{id,name,email,plan}}`.
  - `/v1/auth/refresh` takes `{refresh_token}` and returns the same shape. The
    refresh token **rotates** (save the new one; reusing the old one is a 401).
  - `/v1/auth/google` takes `{token}`; `/v1/auth/logout`;
    `DELETE /v1/auth/account`; `GET /v1/me`.
- **Models:**
  - `GET /v1/models` returns `{object:"list", data:[{id, name, provider,
    blurb, context_length, input_modalities, output_modalities,
    prompt_per_mtok, completion_per_mtok (marked up), free, tools, reasoning,
    web_search, default, created}]}`.
  - `GET /v1/models/defaults` returns `{models:[ids]}`.
- **Chat:** `POST /v1/chat/stream` takes `{model, mode: chat|search|research,
  messages:[{role, content}], tools_enabled, session, reply_language?}` and returns SSE events.
  `reply_language` ("French"; absent or "auto" follows the user's message) adds
  one user-role line after the memory/skills blocks and pins follow-ups to it.
  `content` is a string or OpenAI content parts (`text`, `image_url` data URL,
  `file{filename, file_data}` for PDFs, `input_audio`); bodies up to 32 MiB.
  - `delta {text}` and `reasoning {text}`
  - `sources {sources:[{url,title,snippet}]}`: **new ones only; append**
  - `tool {id, name, arguments}`: a UI tool for the app to render
  - `tool_status {id, name, status: running|done|failed, detail?}`
  - `image {id, mime, data(base64)}`
  - `usage {kind: chat|followups, model, prompt_tokens, completion_tokens,
    cached_tokens, cache_write_tokens, charged_micros}`: one per upstream call
    (follow-ups count toward cost, not context)
  - `followups {questions}`, `done {}`, `error {message, retryable, status?}`
  - **402** `{message, code:"out_of_credits"}` before the stream starts.
  - **Client-executed tools:** the request may carry `client_tools:[names]`
    (UI tools the app runs itself; server tools are never handed over). Such a
    call comes as `tool_wait {id, name, arguments}` instead of `tool`, and the
    loop waits until the app sends `POST /v1/chat/tool_result {call_id, result
    (string or any JSON), is_error?}` (200 `{ok}`; 404 when no turn of this user
    waits for it). The model gets the result (`Error: …` when `is_error`). After
    `CLIENT_TOOL_TIMEOUT_MS` (300 s) it gets `Error (timeout): …` instead. Either
    way a `tool_status {id, name, status: done|failed, detail?:"timed out"}`
    closes the wait. SSE comments keep the stream alive every 15 s meanwhile.
    App side: `chatClientToolsProvider` (names), `ChatController.resolveTool`,
    `ChatSessionState.pendingTools`. Code: `backend-exp/src/tool_wait.zig`.
- **UI tools:** `create_artifact`, `update_artifact`, `render_svg`,
  `render_diagram` (mermaid), `render_chart`, `make_quiz`, `make_flashcards`,
  `make_slides`. Server tools: `web_fetch`, `generate_image`. Schemas are in
  `backend-exp/src/tools.zig`.
- **Gateway:** `POST /v1/chat/completions` with `Authorization: Bearer
  sk-eai-…` (mint one at `POST /v1/keys`) and `X-EveryAI-Session` for
  attribution. LiteLLM prefixes (`openai/…`) are stripped.
- **Images:** `POST /v1/images` takes `{model?, prompt, aspect_ratio}` and
  returns `{mime, data}`.
- **Usage:** `GET /v1/usage/session/:id` returns `{calls, prompt_tokens,
  completion_tokens, cached_tokens, cache_write_tokens, charged_micros,
  last_prompt_tokens, last_completion_tokens}` for a chat conversation or a Code
  session (the composer meter). `usage_events.provider` is openrouter|anthropic.
- **Dev (DEV_AUTH only):** `GET/PUT /v1/dev/upstream` `{anthropic:
  "openrouter"|"anthropic", keys:{openrouter, anthropic}}`: where `anthropic/*`
  chat and gateway calls go (persisted in the `settings` table). Search,
  Research, follow-ups and images always use OpenRouter.
- **Billing:** `GET /v1/plans`, `GET /v1/billing` (plan, quota, wallet,
  recent usage, cached tokens), `GET /v1/usage`, `POST /v1/billing/checkout`
  (`{kind: topup|subscription, amount_cents?, plan?}` returns `{url, mock}`),
  `POST /v1/billing/webhook`.
- **Remote hosts** (`backend-exp/src/remote.zig`, migration 003). A host is a
  desktop running the sidecar; clients are the same account's other devices.
  The backend relays WebSocket frames and never parses a payload. The
  endpoints do the E2E encryption with the public keys exchanged at pairing.
  - `POST /v1/remote/hosts {name, platform?, public_key}` returns 201
    `{id, name, platform, public_key, host_token}`. The `rh_` token is shown
    once. `GET /v1/remote/hosts` returns `[{id, name, platform, public_key,
    online, created_at, last_seen_at, devices:[{id, host_id, name, public_key,
    created_at, last_seen_at}]}]` (approved devices only).
    `DELETE /v1/remote/hosts/:id` and `DELETE /v1/remote/devices/:id` revoke
    at once: live sockets get `revoked` and their next frame closes them (4003
    for a client, 4001 for a host).
  - Pairing, all with the user's JWT:
    - The host asks `POST /v1/remote/pair {host_id}` and gets 201 `{id, code
      "ABCD-EFGH", host_id, expires_at}`: 8 symbols, no I/O/0/1, 5 min, single
      use. The app shows the code as text plus a QR.
    - The client sends `POST /v1/remote/pair/redeem {code, device_name,
      public_key}` (case, dashes and spaces are ignored). It gets `{id,
      status:"pending", device_id, device_token (rd_, shown once), decide_by,
      host:{id, name, platform, public_key}}`. A wrong, spent, expired or other
      account's code is a 404.
    - The host gets a `pair_request` notice and decides with
      `POST /v1/remote/pair/:id/approve|deny`, which also needs the header
      `X-Remote-Host-Token: rh_…` (so a client cannot approve itself). It has
      10 min.
    - The client polls `GET /v1/remote/pair/:id` for `{status:
      open|pending|approved|denied|expired}`.
  - Sockets take their own token in `Authorization: Bearer` or `?token=`:
    - `WS /v1/remote/host` (rh_). A reconnect replaces the old socket, which
      gets `replaced`.
    - `WS /v1/remote/client/:host_id` (rd_, approved only; otherwise 401/403
      before the upgrade).
    - The largest payload is 4 MiB.
  - Framing: **binary = data, text = relay notices (JSON `{type,…}`)**.
    - A client sends and receives bare binary payloads.
    - Host frames start with the **4-byte big-endian channel**: the relay adds
      it to frames from a client and strips it from frames to a client.
    - Notices to the host: `hello {host_id, clients:[{channel, device_id,
      device_name, public_key}], pending_pairings:[…]}`, `client_open
      {channel, device_id, device_name, public_key}`, `client_close
      {channel}`, `pair_request {pairing_id, decide_by, device:{id, name,
      public_key}}`, `replaced`, `revoked`. The host may send
      `{"type":"close_channel","channel":N}`.
    - Notices to a client: `hello {channel, host_online}`, `host_online`,
      `host_offline` (frames sent meanwhile are dropped), `closed`, `revoked`.
  - **App side** (`frontend/lib/features/remote/`): binary payloads are E2E
    frames (`domain/remote_crypto.dart`): `01|v|eph_c` init, `02|v|eph_h|tag`
    accept, `03|counter(8)|ct|tag` data (ChaCha20-Poly1305, per-direction
    keys from 4 X25519 DHs). Inside: JSON mirror messages
    (`domain/remote_protocol.dart`, `Tunnel`): device → host `list`, `open {s}`,
    `close {s}`, `act {id, s, kind, args}`; host → device `sessions`, `reset {s}`,
    `events {s, events}`, `state {s, …}`, `gone`, `done {id, error?}`. **The
    computer runs every session**; phones, tablets and the web are remote
    controls (`host_mirror.dart` runs their actions on the session's own
    controller; devices fold with `MirrorFold` and show `ui/remote_code.dart`).
    Sessions start on the computer only; devices attach pictures and text files
    only; one paired host per device for now. QR: `everyai://pair?c&h&fp&n`.

## Prompt caching (user asked for "proper context caching, for savings")
- The system prompt and tool JSON are compile-time constants with a fixed
  order and no timestamps. Volatile content goes last.
- `anthropic/*` and `google/gemini*` get `cache_control` breakpoints on the
  system prompt and the last message (chat, `CACHE_TTL` 5m). The gateway
  injects breakpoints on the last tool, the system message and the last
  message when the caller sent none (`GATEWAY_CACHE_TTL` 1h).
- Other providers cache on their own.
- Live result: the second agent turn cost 69µ$ instead of 1,113µ$ (94% saved).
  `usage_events` records cached and cache-write tokens.

## Event shapes (from OpenHands, harness removed 2026-10-31)
- The EveryAI harness emits OpenHands-shaped events (`MessageEvent`, `ActionEvent{action:{kind}}`,
  `ObservationEvent`, `ConversationStateUpdateEvent`, …), decoded by `code/harness/events.dart`; the mirror and the
  transcript depend on these shapes. The OpenHands harness, sidecar, agent-server facade and bundling are gone
  (c9b1cb8); sessions stored with `harness: "openHands"` show "can't be reopened". `mcp_config` and skills keep the
  OpenHands JSON shapes.

## Decisions log (user answers, condensed)
- **Coding:** the OpenHands agent-server v1.59.0 (MIT) is a **bundled local
  sidecar**, rebranded with a third-party notice. The UI talks to it over
  REST + WS. Our backend is its LLM provider (per-user gateway key). Desktop
  only for now; a remote harness comes later.
- **Code UI:**
  - top-level Chat | Code switch; auto git worktree per session
  - modes Ask / Auto-edit / Plan / Full auto
  - split transcript + tabbed panel (Diff · Terminal · Processes · Preview)
  - compact tool rows and nested subagent cards
  - mid-run messages queue; ⌥Enter steers
  - per-turn checkpoints with rewind
  - terminal: xterm + flutter_pty; preview webview on mac/win, a window on Linux
  - git: stage/revert hunks, commit+push, PR via gh, merge locally
  - FakeHarness mock mode
  - projects: open folder, clone, or new
- **Question cards (2026-10-29):** the coding agent can ask the user
  questions. Each is single-choice **MCQ (radio)** or **multiple-answer
  (checkboxes)**, every option has a label + description plus an "Other"
  free-text field, and a card holds 1–4 questions, answered together.
  - Plan: an OpenHands **client tool** `ask_user_question({questions:[{question,
    header, options:[{label, description}], multi_select}]})`, registered via
    `client_tools` on `POST /api/conversations` (v1.59 supports client tools
    natively, so no MCP server is needed).
  - The SDK acks the call at once (ClientToolObservation), and the tool
    description tells the agent to end its turn and wait.
  - The app renders the card from the ActionEvent and sends the answers back
    as the next user message (JSON plus a readable summary).
  - The session shows needsInput plus an OS notification. Plan mode uses it
    to clarify before building.
  - Consider the same card for chat (a UI tool) later.
- **Models:** a Shop window (the full OpenRouter catalog) plus **My models**
  (a local list seeded with the featured defaults: Haiku/Sonnet/Opus 5.5,
  GPT-6.1 Sol/Terra, GPT-5.4 mini, and 2 free Chinese models).
- **Billing:**
  - plans Free/Pro/Max plus prepaid top-ups, all at cost ×1.15
  - zero-cost models are free on every plan
  - Stripe test mode, mocked until keys arrive
- **History:** chat history stays **local-only** (Drift).
- **Search:** Search = the OpenRouter web plugin (engine `exa`; native search
  only cites sometimes). Research = `perplexity/sonar-deep-research`.
  Follow-ups come from `google/gemini-3.5-flash-lite`.
- **Order:** A backend core + app switch → B Code UI → C chat tools
  (artifacts, SVG/diagrams/charts, quiz/flashcards, slides→PPTX).

## Progress log
- **Earlier (committed):**
  - rename to EveryAI; pip → uv
  - frontend rebuild: native UI on 6 platforms, Riverpod FSMs, Drift
  - Claude/Perplexity-style chat layout: model picker in the composer,
    centered home, collapsible rail, modes, sources/citations, follow-ups,
    retry/edit
  - macOS rail and vibrancy fixes
  - commits 36d53ad, 9356645, a8fba50, 7b0b6d7, 23642d8
- **2026-10-29, Phase A backend-exp (commit 5da3df4):**
  - The whole `/v1` API is built and passes `zig build test` (16 tests).
  - Live-verified against OpenRouter with Haiku 5.5:
    - search with exa citations
    - the quiz UI-tool loop
    - follow-ups
    - the gateway via the `openai` Python client (non-stream + stream), with
      cache hits
    - `/v1/images` (a 1.2 MB PNG)
    - ledger debits
  - Fixes since then, not yet committed:
    - models: blurbs cut at word boundaries, `~vendor` slugs normalized
    - `/v1/images` takes `model`
    - sources events send only new items
- **Anole PRs #154/#155 merged (v0.4.1) and adopted (2026-10-30):** local `net/sse_client.zig` and `db/migrate.zig` deleted; `Parser.init(gpa, reader, .{})`, `anole.db.migrate(db, ctx, &migrations.all)`.
- **A2 frontend switch (commit 8e96afb):**
  - `/v1` auth with rotated refresh tokens saved; SSE transport with all events; image models through `/v1/images`.
  - Catalog provider, cached under KeyValues `catalog.json` and refreshed hourly. Featured order is Claude, GPT, then the free models.
  - Model shop (`features/models/ui/models_screen.dart`): search, filters, vendor chips, Add/Added.
  - Picker with search; vendor monograms.
  - Billing: `features/billing/`, route `/settings/billing`; Top up on 402.
  - "Rich answers" toggle (`tools_enabled`).
  - Verified live on macOS: search with sources, the quiz tool, shop, plan & usage.
  - `config/dev.json` points at `:8080` with SSE on (gitignored; `example.json` updated).
- **Phase C, first pass (commit 3643e1f), started early at the user's request ("can't interact with the artifact; side window like Claude"):**
  - Code lives in `frontend/lib/features/artifacts/`:
    - `domain/artifact.dart`: `Visual` (decoded tool call), `VisualKind`, and `artifactsIn(messages)`, which groups `create_artifact`/`update_artifact` by id into versions. There are no new tables; history stays in message parts.
    - `artifact_providers.dart`: `artifactPanelProvider(conversationId)` (ArtifactTarget | VisualTarget), `conversationArtifactsProvider`, and `quizAnswersProvider(callId)` (a bitmask per question).
    - `ui/visual_view.dart`: `VisualBody` (renderer switch) and `InlineVisual` (the chat card). Quiz, flashcards, chart, svg and diagram render inline; document, code, html and slides open the panel.
    - `ui/artifact_panel.dart`: header with versions ‹ ›, open in browser (html/diagram), copy, save (file_selector), close. Exports via `exportOf`, plus `pptxOf` for decks.
    - Renderers:
      - `quiz_view` (radio + checkbox `answer_indices`, Check, explanations, score, "Explain my mistakes" sends a chat message)
      - `flashcards_view` (3D flip, keyboard, known/learning)
      - `chart_view` (fl_chart: line, area, bar, scatter, pie)
      - `svg_view` (sanitizer)
      - `web_view` (InAppWebView; Mermaid via the jsDelivr CDN; Linux falls back to source + open in browser)
      - `slides_view` (960×540 canvas, 4 themes, notes)
    - `export/pptx_writer.dart`: a minimal OOXML writer, validated with python-pptx and LibreOffice.
  - `chat_screen.dart`: `_WithPanel` (split ≥720pt, overlay below). Auto-opens on create/update_artifact and make_slides.
  - Composer: a mode menu when narrow; the model chip ellipsizes.
  - New deps: flutter_svg, fl_chart, flutter_inappwebview, file_selector, archive.
  - Verified live: interactive quiz, a document artifact in the panel, chart inline + panel, a slides deck auto-opening, PPTX export.
  - Still missing:
    - quiz/flashcard state is per session (not persisted)
    - no speaker notes in the PPTX (needs a notesMaster)
    - the Artifacts sidebar page is still "coming soon": list `artifactsIn` across conversations via the repository
    - no editing of artifacts in the panel
    - Mermaid offline asset
    - resizable panel divider

- **Phase B, steps 1–2 (commit c531059): Code workspace on FakeHarness.**
  - `frontend/lib/features/code/`:
    - `harness/events.dart`: sealed `HarnessEvent` decoded from OpenHands `kind`s (ChatMessage, ActionCall, ToolResult, StreamDelta, StateChange, ConversationFailure, UnknownEvent). An ActionCall's `action` merges `tool_call.arguments` (client tools) under the typed action.
    - `harness/harness.dart`: `Harness`/`HarnessSession` interfaces and `SessionSpec`.
    - `harness/openhands_harness.dart`: the REST + WS client (untested against a live server). It sends `llm.model` `openai/<id>` with `base_url` pointing at the gateway, registers `client_tools: [askUserQuestionSpec]`, and dedups resent events on reconnect.
    - `harness/fake_harness.dart`: `demoTurns`, a scripted counter-app session. Every action waits for `respond` unless Full auto; the question tool ends the turn.
    - `domain/transcript.dart`: `TranscriptBuilder` folds events into items: UserTurn, AgentText, ExploreGroup (consecutive read-only steps), StepItem, SubagentItem, PlanItem (consecutive updates merge), QuestionItem (an answers message attaches to it), and NoticeItem. `pending` holds every action without a result while status is waiting_for_confirmation.
    - `domain/agent_mode.dart`: Ask (reads are free; commands and edits ask), Auto-edit, Plan (rejects writes and sends the plan prompt), and Full auto (NeverConfirm). `isReadOnly` refuses commands chained with `;&|>`. Also holds `askUserQuestionSpec`.
    - `domain/questions.dart`: Question, QuestionAnswer, `answersMessage` (a summary plus fenced JSON) and `parseAnswers`.
    - `domain/line_diff.dart`: an LCS line diff with folded context.
    - `code_providers.dart`:
      - `harnessProvider` (FakeHarness for now)
      - `codeProjectsProvider` and `codeSessionsProvider`, JSON in Preferences `code.projects` / `code.sessions`
      - `codeSessionProvider(id)`: the controller. It auto-responds per mode, queues messages while busy, `steer` interrupts and sends, `startBuilding` switches Plan to Auto-edit.
    - UI:
      - `ui/code_home.dart`: `/code`, with the project picker, "Try the demo" (`demo://counter-app`), and recent sessions
      - `ui/session_view.dart`: `/code/s/:id`
      - `ui/code_composer.dart`: Enter sends or queues, ⌥Enter steers, Esc stops; mode menu
      - `ui/transcript/`: items, `question_card.dart` (radio/checkbox + Other, 1–4 questions, ⌘↩ submits), `approval_card.dart`
    - Sidebar: a Chat | Code switch; Code mode lists projects → sessions with status dots.
  - Tests: `test/features/code_test.dart` (9).
  - Verified live on macOS: demo session → question card → approvals → edit diff → subagent → tests → Done.
  - UI fixes in the same commit, at the user's request:
    - the chat user bubble is right-aligned (wrapped in `Align`)
    - the Code composer model label sits at the right
    - macOS page titles: `AdaptivePage` shifts the ToolBar title by `_macTrafficLightInset` (ToolBar reserves 70pt when macos_ui's own sidebar isn't used)
  - Live UI testing: `scratchpad/type.sh` and `cmdenter.sh` refuse to type unless EveryAI is frontmost (a stray keystroke once landed in the terminal); `scratchpad/scroll x y lines`.
  - Not done yet:
    - no panes (Diff/Terminal/Processes/Preview)
    - no worktrees or git
    - no sidecar
    - sessions reopened after an app restart are empty (FakeHarness doesn't persist; the real server replays history)
    - no OS notifications

- **Brand reskin (commit 2f1323c), from the user's `brand/` kit (v1.0; the folder stays untracked, it is the user's source of truth; see `brand/README.md`):**
  - Tokens: `lib/core/theme/everyai_brand.dart` (copy of the kit's Dart tokens). `EveryTheme` maps the README role table; filled buttons use `primary`/`onPrimary` (violet 500 + white in both themes); `accent` is for text/links/icons. Statics `cardRadius` 20, `panelRadius` 24, `bubbleTail` 6.
  - `lib/core/ui/brand.dart`: `BrandMark`, `EveryMarkActivity(thinking|streaming|tool)` (CustomPainter from the mark parts), `BrandGlyph(name, active)` (paths in generated `brand_glyphs.dart`), `BrandEmptyState`, `BrandField`.
  - `GlassSurface(level: thin|regular|thick)` in `adaptive.dart`; popovers and toasts are thick.
  - `AdaptiveButton` is compact by default (Cupertino small, macOS regular, Material 34pt dense, 14pt labels); `large:` (defaults to `expand`) for full-width form buttons.
  - `Host.hasTrafficLights` (macOS host, any design language) drives the sidebar's 92pt title-row inset; before this the lockup sat under the traffic lights in Cupertino.
  - Icons: macOS/iOS (single 1024 with dark + tinted)/Android adaptive + monochrome/Windows ico/web/Linux hicolor (CMake install + `gtk_window_set_icon_from_file`, not compiled yet). Splash via `dart run flutter_native_splash:create` (config in pubspec).
  - Verified on macOS (Cupertino design, which the user runs): chat, Code home and session (the mark animates while working), shop, question card, light mode.
  - Not used yet: avatar (for "EveryAI · Auto"), Icon Composer layers, patterns, grain overlay.

- **Real agent-server wired up (2026-10-29):**
  - `frontend/tool/fetch_agent_server.sh` downloads `agent-server` v1.59.0 for this OS/arch into `frontend/.agent-server/` (gitignored) and checks SHA256SUMS.
  - `features/code/sidecar/` (conditional `_io`/`_stub`): `createSidecar()` either uses `AGENT_SERVER_URL`+`AGENT_SERVER_KEY` or spawns the binary (`AGENT_SERVER_BIN`, else bundle Resources / app-support `bin/`) on a free loopback port with a random `OH_SESSION_API_KEYS_0`, stable `OH_SECRET_KEY` (`secret.key`), cwd = app support `agent-server/` (conversations persist in `workspace/conversations`, log in `server.log`, `server.pid` lets the next launch kill an orphan). Polls `/ready` (~8–15 s cold). Stopped on Cmd-Q via `AppLifecycleListener`.
  - `code_providers.dart`: `harnessFor(ref, workingDir)` (demo:// → FakeHarness, else OpenHandsHarness on the sidecar) and `gatewayKey(ref)` (POST `/v1/keys` once, kept in prefs `code.gateway_key`; unauthenticated when `DEV_SKIP_AUTH`, like billing). LLM base URL = `API_BASE_URL` + `/v1`. FutureProviders read with `ref.read(.future)` hung here, hence plain functions.
  - `createSampleProject()` makes a Dart counter repo under app support `sample-projects/` ("Sample project" button / project picker); the scripted demo is still there.
  - OpenHands quirk: the `task` tool (subagents) breaks conversation create in 1.59.0; removed from the tool list.
  - macOS app is **unsandboxed** now (entitlements); the DB moved to Application Support (`core/db/db_location_io.dart` copies the old container DB on first run).
  - Verified live: Ask-mode session on the sample repo with Haiku via the gateway → explore, approve, edits + tests, `dart test` 3/3, Done. Ledger: 7 gateway calls, 58% of prompt tokens cached.
- **Dev runner:** `scripts/dev.sh [macos|web|ios-sim|ios|<device>] [-- flutter args]` starts backend-exp (reuses one on :8080), fetches the agent-server for macOS, writes `.dev/defines-<target>.json` from `config/dev.json` with the right `API_BASE_URL` (LAN IP + backend `HOST=0.0.0.0` for a physical iPhone), and `flutter run`s. New backend setting `HOST` (default 127.0.0.1).
- **Web/iOS:** web needs `web/sqlite3.wasm` + `web/drift_worker.js` (added, from drift 2.35.3); verified loading the catalog from the backend. iOS Simulator build verified (this Xcode has no Simulator.app; it runs headless, `xcrun simctl io booted screenshot`). The Code switch shows on desktop hosts only.
- **Type scale:** Cupertino on a desktop host uses desktop sizes (`_desktopCupertinoText`, 14pt body; text fields 14.5); lighter sidebar/headlines.

- **Meter, attachments, Anthropic key (2026-10-29; commits 59ae160, 4c4b51b, 114106d):**
  - `backend-exp/src/anthropic.zig`: native Messages adapter behind `openrouter.Upstream`. It translates OpenAI requests (system hoisted, tool_use/tool_result merged, image/PDF blocks, cache breakpoints capped at 4, sampling params dropped, forced tool_choice → auto, adaptive summarized thinking, `fallbacks:"default"` on Sonnet/Opus 5.5) and turns Anthropic SSE/JSON back into OpenAI chunks. Cost comes from catalog prices (`Catalog.pricesOf`: 5m/1h cache writes, the >100K tier). `App.route(model, native_ok)` picks the upstream.
  - The key is **`ANTHROPIC_API_KEY`** in the root `.env`; `CLAUDE_API_KEY` there is rejected by the API (401). Thinking blocks are not sent back; the 5.5 models accept tool loops without them (probed).
  - Verified live on the Anthropic key: chat tool loop with cache reads, the gateway (stream + non-stream), image+PDF+text attachments (same answer and ~same cost via OpenRouter), and an OpenHands session with an image ("Red"), attributed via `/v1/usage/session`.
  - App: Settings → Developer ("Claude models bill to"), `features/settings/dev_upstream.dart`. The switch is currently **on Anthropic**.
  - `features/usage/`: `UsageTotals`, `formatTokens`, `UsageMeter` + `ContextRing` (popover breakdown). Chat saves a `UsagePart` per turn; Code polls the session endpoint after OpenHands `stats` events (`codeUsageProvider`) and sends `max_input_tokens`.
  - `features/attachments/`: `Attachment`/`AttachmentKind` (limits, `ModelSpec.accepts` via the new `ModelSpec.inputs`), `pickAttachmentFiles` (native picker greys out unsupported types), `AttachmentDropZone` (desktop_drop), `AttachmentTray`/`AttachmentChip`. Chat: `AttachmentPart` (Blobs), `messageContent` builds content parts. Code: `uploads/` saves into `<project>/.everyai/uploads` (git-excluded), `[Attached: …]` note (rendered as chips), images as OpenHands `ImageContent` with `capability_overrides.supports_vision`.
  - Not verified by clicking through the macOS UI (the machine was in use); the picker, drop zone, tray and meter were checked by analyze/tests only.

- **Code bug fixes (2026-10-30; commits c6cd611, 9183510, dd41963)**, from the user's report that question cards deactivate, Plan mode refuses everything, and agents turn into chatbots:
  - Root causes, found in the agent-server's persisted events:
    - `openQuestion` only counted the last item, so the agent's follow-up text disabled the card.
    - `isReadOnly` refused any `; & | >`, so Plan rejected every exploration command and Ask asked for every read.
    - Mode changes were never told to the model.
    - Session events were broadcast-only, so events before the view subscribed were lost.
    - The transport and gateway were fine.
  - `domain/shell_readonly.dart`: a quote-aware classifier with per-segment allowlists, git read subcommands, and `/dev/null` and fd redirects; `$(…)`, subshells, heredocs and `&` are refused.
  - Mode notes:
    - `modeNote`/`splitModeNote` (`<everyai-mode name="plan">…</everyai-mode>`) go on the first message and on the first message after each switch.
    - `Transcript.notedMode` tracks the last note, and `UserTurn.mode` shows a chip.
  - Prompts:
    - `workingRules` go into `agent.agent_context.system_message_suffix` (verified in the SystemPromptEvent).
    - `AgentMode.planRefusal` explains what still works.
  - The `present_plan` client tool gives a `PlanProposal` item and `ui/transcript/plan_card.dart` (Start building switches Plan to Auto-edit; Keep planning).
  - The question card is paged (tabs, Back/Next, number keys, still-to-answer). A free-text reply settles it as "answered in chat".
  - The harness:
    - `OpenHandsHarness.located(locator)` re-resolves the sidecar before each request and reconnect.
    - The session buffers history and replays it to every listener.
    - `ConnectionChange` events drive a reconnecting banner; attach returns a 404 as a clear error.
    - `statuses(ids)` feeds `codeStatusesProvider` for sessions that aren't open.
  - `tool/agent_eval/`: `driver.dart` (`EvalRun`, a headless controller that plays the user), `scenario_test.dart`, and `restart_check_test.dart`. These are live; run them explicitly with env vars (see their headers). Use a private agent-server on its own port (not the app's).
  - Live, on Haiku 5.5 via the Anthropic route:
    - Plan: explore, 4 questions, present_plan, approve, build, tests, done (40 s).
    - Ask: the same with the user's form prompt.
    - Restart: the session followed a new port and key with no lost or duplicated events.
- **PDF → Markdown freeze (commit a917d19):** Haiku read the PDF fine and made a markdown artifact with TeX in table cells. `IntrinsicColumnWidth` measures cells, so the paragraph asks the inline math for `computeDryBaseline`. flutter_math_fork's `RenderLine` lacks it, so layout failed every frame and the debug app froze. `everyai_markdown/lib/src/render/math.dart` wraps math in `_DryBaseline` (estimates from the dry size). The regression test is `test/math_layout_test.dart`. App run logs only go to the terminal that ran `flutter run`. The chat DB is `~/Library/Application Support/dev.alidirect.everyai/everyai.sqlite` (tables `conversations`, `messages`, `message_parts`, `blobs`), useful for replaying what the model sent.

- **Artifacts: in-place edits, figures, downloads (commit dc3c90c, 2026-10-30):**
  - `edit_artifact {id, edits:[{old_text,new_text}]}` in `tools.zig`. `chat.zig` `Artifacts` seeds content from `<artifact id kind title>` blocks in history, applies the edits and replies with misses (an edit with no matches isn't shown).
  - The app now sends what UI tools made in earlier turns (`toolOutputsByMessage` in `chat_transport.dart`); before this the model never saw its artifacts after the turn and re-created them.
  - `artifactsIn` applies edits (`applyArtifactEdits`, whitespace-tolerant; `edit_missed`).
  - ```svg / ```mermaid blocks render in `ChatMarkdown`; raw `<svg>` blocks get fenced (`fenceRawSvg`).
  - `artifacts/export/`: `doc_model.dart` (GFM → blocks), `pdf_writer.dart` (pdf pkg, Noto Sans in `assets/fonts/NotoSans`), `docx_writer.dart`, `svg_raster.dart`, `downloads.dart` (`downloadsOf`, `exportOf`, `pptxOf`); `ui/download_button.dart` on cards and panel.
  - Live: Haiku edited the assignment doc in place with an inline SVG ($0.007); the saved PDF (8 pages) had the figure.
- **Research docs (untracked):** `docs/research/opencode-agents.md`, `hermes-agent.md`, `hermes-chat-tooling.md`, `deepseek-harness.md`.

- **Build pass, tracks 0–1 (2026-10-30; commits d9d0bd4..d2081ad, then 74663ff):**
  - Chat: tool-use enforcement and artifact rules in `tools.zig`; typed tool errors (`tool_check.zig`, schema-driven); client-executed tools (`tool_wait.zig`, SSE `tool_wait`, `POST /v1/chat/tool_result`, `ChatController.resolveTool`); truncation recovery in chat and gateway; SSRF-safe `net/safe_fetch.zig` for web_fetch; DeepSeek cache hits.
  - Code: mode re-asserted on every message; question/plan answers held inside the tool call (respond_to_confirmation); our own permissions (floor, allow/deny, dangerous classifier, once/session/always, denial templates; no NeverConfirm); AGENTS.md/CLAUDE.md injection with nested hints; Stop kills the session's process tree; doom-loop guard; output spill to `.everyai/spill`; `compact()` into a fresh conversation; `run_subagent` child conversations; rich tool rows with highlighting; live Changes/meter.
  - Review fixes: cloned repos can't approve their own commands or read outside the repo; floor/readonly bypasses closed; Stop spares tmux panes.
  - Anole is now the v0.4.1 tag (url + hash in `build.zig.zon`), not the local path.
  - Not live-tested (user defers testing). Leftovers are sub-bullets in TODO.md.

- **Build pass, tracks 2+4 (2026-10-30; 74663ff..3d6ff3f):**
  - Images via OpenRouter `/images` (`images.zig`): `n`, quality, `input_references`, ids `img_<n>`/`upload_<n>`, `edit_of`; Recraft vector engine (`VECTOR_MODEL`); image artifacts with versions (`image_view.dart`).
  - `web.zig`: model-callable `web_search`, one source ledger for all citations, paged `web_fetch` (`offset`, `max_chars`).
  - Reasoning passback within a turn, `effort` request field + composer EffortMenu (per chat). Aux routing table for side jobs; follow-ups pinned to the user's language.
  - SVG design brief, 6 style presets after the cached prefix, stable ids; `/v1/figures/polish` (`polish.zig`); SVG eval assets (not run).
  - Chat `ask_user` card (client tool); local memory (`features/memory/`, memory + search_chats client tools, Settings → Memory).
  - Artifacts: Mermaid/math checks in a hidden webview with PNGs in PDF/Word, offline Mermaid asset, sandboxed HTML (CSP meta first), inline widgets (send-back confirmed), Excalidraw drawings, hand-editing, PPTX notes, Artifacts page, resizable divider, persistent quiz/cards.
  - Review fixes: credit preflight for search/follow-ups/image batches, remote Markdown images load on tap, memory kept out of system authority.
- **Code MCP servers (commit 834795a):** Settings > Code > MCP servers (`/settings/mcp`), global or per project, stored in Preferences `code.mcp_servers`; passed as `agent.mcp_config` (1.59 shape: `{name: {command,args,env} | {url,transport,headers}}`). Local commands need consent of the exact command+args+env (`McpServer.approved`); `reviewMcpServer` reuses `floorReason`/`dangerReason`. `MCPToolAction` is never read-only: Ask/Auto-edit/Plan ask, Full auto runs, `Mcp(glob)` rules match the tool name. 1.59 has no MCP elicitation handler.

- **Build pass, tracks 3+5 (2026-10-30; 3d6ff3f..336a1ff):**
  - Code MCP servers (`code/domain/mcp_servers.dart`, `/settings/mcp`): flat `mcp_config` map (verified against SDK v1.59.0), consent review, presets (Playwright, Penpot, AntV, draw.io; not installed). MCP calls always ask except in Full auto. Elicitation needs the backend MCP client.
  - Skills (`features/skills/`, `/settings/skills`): sent as `agent_context.skills` (agentskills format; server folder scans stay off); inline `!cmd` lines escaped; strict import validator; project skills digest-trusted. Chat: client-executed `load_skill` / `read_skill_file`. Bundled Apache-2.0 skills in `assets/skills/`.
  - Slash (`features/slash/`): one `/` popover in both composers; custom commands `.everyai/commands/*.md`; Chat and Code built-ins incl. /btw, /review, /goal (judge), /commit, /pr, /learn, /morning.
  - Known gap: project custom commands from cloned repos have no digest trust gate yet (mode switch restricted only).

- **Build pass, track 6 + Code workspace (2026-10-30; 336a1ff..0a0a7bf):**
  - Agent library (`features/agents/`, `/settings/agents`): `.everyai/agents/*.md`, built-ins in `assets/agents/`, digest trust for project agents; `run_subagent` takes `agent`.
  - Ultra (`code/ultra/`): `ultra_plan` client tool → pure-Dart engine (phases, parallel/pipeline, worktrees per writing step, schema retry, verify, critic), caps 16/150/$25/2h, Max only, journal resume; progress tree UI. Orchestrator spend is now counted in the cap.
  - Code UI: Harness → Model → Effort popover with live `switch_llm`, no bottom sheets, Code top bar with layered settings JSON + system prompt + budget; panes Terminal (xterm + flutter_pty), Processes, Preview; `present_files`; OS notifications (osascript/notify-send).
  - Infra: gateway key in secure storage with re-mint on 401; sidecar crash restart + reattach; agent-server bundled into the macOS app; conversation rewind via fork/navigate.
  - Remote host: `backend-exp/src/remote.zig` relay (opaque E2E frames, pairing codes) + `features/remote/` (X25519 + AEAD, QR, RelayHarness). Pairings are cleared on sign-out.

- **Build pass, leftovers (2026-10-30; 0a0a7bf..HEAD):** Anole 0.4.1's `sse.Parser` and `db.migrate` adopted (local copies deleted; list in `src/migrations.zig`); Anthropic adapter prices the served model, continues `pause_turn`, `by_kind` usage; modality guard (400 `unsupported_modality`); relay sockets need the user's JWT; `DEV_AUTH_LAN` guard; usage aggregates (`/v1/usage?group=&by=`) + Settings → Usage; clipboard paste, blob GC, full-size images; trust gate for project custom commands; window persistence; `docs/ROADMAP.md`, `docs/CODE_ROADMAP.md`. Final state: zig 91/91 steps, flutter analyze clean, 613 flutter tests pass. Nothing in this pass was live-tested.
- **Remote control (2026-10-30, commit adc5811):** the old "phone drives the host's agent-server"
  path (`RelayHarness`, `remote://` projects) is gone. The Mac's `CodeSessionController` exposes
  `mirrorEvents` + a sync `mirrorTap`; `HostMirror` streams them (deltas too) plus a state snapshot
  (mode, queue, approval flags, remember patterns) to every device following a session, and runs
  device actions there, so several devices and the desktop drive one session together. Off desktop,
  `/code` and `/code/s/:id` route to `RemoteCodeHome` / `RemoteSessionScreen`; the sidebar lists the
  host's sessions; Settings → Remote shows hosting on desktop and pairing elsewhere.
  `test/features/remote/mirror_test.dart` covers transport + an end-to-end mirrored FakeHarness session.
- **Type scale + one menu style (commit d159e82):** `core/theme/every_type.dart` `EveryType` (largeTitle/title/headline/body/callout/caption/footnote/micro, desktop vs touch sizes, max semibold) via `EveryTheme.type` plus `.medium/.semibold/.mono/.tint()`. No literal font sizes in screens (except slides canvas, PDF export, avatars). Cupertino text theme built from it on iOS too. `AdaptiveMenuButton` = `AnchoredPopover` + `PopoverRow` on every platform; `MenuTrigger` for value pickers. Not checked visually on iOS yet.

- **Chat harness per mode (2026-10-30; d35d61b..4709a36):** plan in `~/.claude/plans/calm-strolling-swing.md`.
  - Question cards: options ending " (Recommended)" show an accent tag (Code + chat specs ask for it).
  - Charts: one spec (`artifacts/domain/chart_spec.dart`) for `render_chart` and ```chart blocks in Markdown
    artifacts; fl_chart in the app, `export/chart_svg.dart` for PDF/Word/PNG/SVG; CSV + data table. Server flags
    bad ```chart blocks after artifact calls.
  - Modes: `backend-exp/src/modes.zig` constant block per mode as a 2nd system part (own cache breakpoint).
    Learn, Summarise, Search (model-driven web_search/web_fetch; plugin only without tools), Research.
    `suggest_mode` UI tool → "Run as <mode>" button (`rerunIn`). Slash: /teach (Learn; /learn is make-a-skill), /summarise.
  - `web.SearchCache`: per user+chat, 1 h, 300 entries; repeats are free and marked.
  - Research (`research.zig`): lead = user's model; `research` tool runs researchers in parallel on a roster
    (tiers by depth Quick/Standard/Deep), shared ledger behind a lock; report gating, citation check, one nudge.
    App: depth menu, researcher live steps, usage kind `research`. Sonar only as no-tools fallback.
  - Not done: `summarise_parts` map-reduce for over-long sources; no live run yet (eval gate suspended).
- **Backend audit against the Anole docs (2026-10-30; 77e0c84..2a99983):**
  - Security: Google sign-in keyed on `sub` only (verified email for new accounts, a taken address is 409, never linked);
    `/v1/auth/*` rate-limited 10/min per address and pairing 10/min per user (`App.limiter`); decoy Argon2 hash for
    unknown emails; 401s send `WWW-Authenticate`; `.env` files are read only in development.
  - Billing: `charge`, `startPeriod` and period renewal run in `app.db.transaction` (the `...In(db, ctx, …)` helpers take
    the client or a `Tx`); the Stripe webhook binds a typed event with optional fields (signed-event test).
  - `Upstream.post` / `openrouter.complete` take `openrouter.Ctx` (= `anole.db.Ctx`, `ctxOf(req)`); researchers use their
    own Ctx; the research group is cancelled on early return.
  - Build `.profile = .web` minus unused features (91 → 61 steps). Client: 60 s timeout, retries, breaker; the default
    30 s request deadline with `req.setTimeout` on slow routes; turns end retryable when the server drains.
  - Typed bodies (`FetchBody`, field_rules on images/polish; `bindWith` where a field is a `std.json.Value`); the app's
    error parser shows the first 422 field problem. Catalog: one refresh at a time, 60 s backoff, loaded at start.
  - Not done, on purpose: `anole.cached` on /v1/models (the app always sends Authorization, which the cache skips);
    WebSocket idle timeout (the relay client never pings, so it would cut idle sessions; needs a protocol heartbeat);
    jobs cron (no jobs store); Duration-typed config (would change the env formats).

- **Settings overhaul, Steps 1–3 of `~/.claude/plans/settings-ui-overhaul-i-modular-bubble.md` (2026-10-30):**
  - Settings is a modal (`features/settings/ui/settings_modal.dart`, `showSettings(context, section:, anchor:, args:)`):
    ≥760pt a centered glass modal with search + grouped section list; narrower a drill-down. `settings_registry.dart`
    holds `SettingsSection`, the search index (`settingsEntries`), `settingsTargetProvider` (jumps) and
    `SettingsAnchor` targets. Old `/settings/*` and `/code/settings?…` routes redirect to where the user was and open
    the modal (`pendingSettingsProvider`, shell). Screen bodies are `…Body` widgets (no AdaptivePage).
  - Account row + menu: `settings/ui/account_menu.dart` (placeholder name/plan; help/apps/learn more are dead).
  - Reply language: pref `chat.reply_language` → request `reply_language` → `chat.zig` adds one user line after
    memory/skills and pins follow-ups (`routing.fixedLanguage`).
  - Code section: `code/settings/setting_defs.dart` catalog + `code/ui/code_settings_section.dart` (Global | Project
    with "Just me" | Session rows, + Add setting, View as JSON, See full prompt, `PermissionsEditor` + rule builder).
    Files via `settings.dart` `readLayer`/`writeLayer` (atomic, unknown keys kept). Project allow rules go to the app
    store (project files can't allow). The JSON editor (`code_settings_screen.dart`, `parseLayer`) is gone.
  - BYOK UI (`settings/ui/api_keys_section.dart`, `byok_keys.dart`, keychain `byok.<id>`, unused) and static Plans
    (`billing/ui/plans_preview.dart`, anchor `plans`). `AdaptiveSegmented` (`core/ui/segmented.dart`);
    `showAdaptivePrompt(obscureText:)`. No macOS click-through yet (TODO.md §10).

- **Harness: retries, per-call approvals, gentler compaction, model families (2026-10-30; 6a856c0..0fc7f33):**
  - Retries: `GatewayClient.completeWithRetry`/`raw(retry:)` resend on 408/409/425/429/5xx/529, drops and mid-stream overloaded/rate-limit errors, not after a tool call started streaming. 8 attempts (15 for Max/Ultra), backoff 1→60 s ±25%, Retry-After honoured up to 5 min. Transient `ConversationStateUpdateEvent{key:"retry"}` → `RetryState` → `Transcript.retry` / `RetryRow` (Retry now / Stop; mirror action `retry_now`). The gateway forwards upstream `Retry-After`; Anthropic 529 → 503 with `code: 529`.
  - Approvals: one decision per action id (`respond(callIds)`; none = all undecided; `PerCallApprovals`). Refused calls return as refusals and the run continues; only Deny all or Stop parks it. Controller auto-answers per call (`CodeSessionState.decided`, `rememberBy`); `ApprovalCard` stacks rows under Allow all / Deny all. OpenHands stays batch-wide.
  - Parallel reads: read-only bash (`runsInParallel`) batches with the read tools, up to 8 at a time.
  - Compaction: `clearOldToolOutput` (>40K tokens of output older than the last 3 model steps → 20K, placeholder) before summarising; continuation re-injects `<approved-plan>`, `<todos>`, `<files>` (last 5 touched, 8K/30K, marked read), `<skills>`. State in `state.json`.
  - Families: `model_family.dart` `familyOf` fixed per session; `familyRules` `<MODEL-NOTES>` after `harnessRules`; GPT gets our own V4A `apply_patch` (`apply_patch.dart`) instead of edit/write, treated as edits per file.
  - Verified: analyze clean, 686 flutter tests, zig tests pass. Not live-tested or clicked through.

- **BYOK, UI fixes, Gemini/Kimi run fixes (2026-10-31; b22f889..39b53c2):**
  - BYOK: only OpenRouter (every model + side calls) and Anthropic (`anthropic/*`, native adapter). Keys in the keychain
    (`byok.<id>`); the app sends the chosen one as `X-Provider-Key-OpenRouter|Anthropic` (`ModelBilling.headersFor`,
    snapshot `ModelBilling.current` for the Code gateway client). Backend `byok.zig`, `App.routeFor`/`App.aux`: calls on a
    key skip preflight, record `provider = openrouter-byok|anthropic-byok`, charged 0; `/v1/usage/session` adds
    `byok_cost_micros`. Per-model biller pick in the shop (Add menu when >1 account; prefs `models.billers`); default =
    most specific key. Ultra open on own-key models, capped by session budget or `byok.ultra_cap_usd` ($25).
    Not covered: Search mode without tools on a Claude model with only an Anthropic key falls back to credits (needs the
    OpenRouter web plugin). Nothing live-tested.
  - `AdaptivePage.header` pins a search/filter header below the translucent bar (Chats, Artifacts, Model shop).
    `AnchoredPopover` positions from the trigger's rect (hover-faded triggers made panels jump to the window corner).
  - Harness: mid-stream errors retried by message too; gateway `: progress` no longer blocks retries; fork brief says
    phase notes aren't theirs; research refusals before approval; refused writes claim no files; pkill/killall of user
    apps is a floor; mkdir under scratch in the plan phase. Open: a shared per-model rate limiter (Gemini new-account
    20 RPM), a built-in screenshot tool (Kimi spent 8 min trying), forks waiting on approvals nobody sees.

- **Orchestrator, big files, debugging tools (2026-10-31; 302e85c..bf5d5ce):**
  - Fork questions: a fork's `ask_user_question` is held and routed to its orchestrator as `<fork-question>` (held call
    returns `forkAsks`, siblings move to the background; background forks get a message). Orchestrator tools
    `check_forks`, `answer_fork`, `stop_fork` (client tools answered in `CodeSessionController._syncForkTools`; child
    `answerFromOrchestrator`). Tier block `_orchestrating`: monitoring forks is the main job, integration is "done".
    `PhaseFlow.forkAsking` lets the user be asked during research; `onAnswer(callId:)` reads per-call reports.
    Not covered by a controller-level test (harness + phase tests only).
  - `write` `mode: "append"`, ~300 lines per call in the schema, oversize writes land with advice, cut-off writes get
    escalating advice (`_cutOffAdvice`). Research summary in the commit body (Cline/Roo/opencode/Gemini CLI/Plandex).
  - `browser` tool (`browser_io.dart`, CDP over WebSocket, headless Chrome with a per-session profile in the session
    dir; closed at run end/stop) and `screenshot` (`window_capture_io.dart`: JXA window list + `screencapture -l`, only
    windows of processes under the session's shells or run from inside the project). Debugging section in rules.

- **2026-10-31, later:** Option-Enter steer fixed (a message sent while the stopped run unwinds now runs; harness
  test), shortcut hints via `Host.enterKeys` (text-style ↩, Ctrl/Alt+Enter off Apple; approvals take Ctrl+Enter).
  README rewritten for the harness/modes/BYOK/remote, with the BrowserOS benchmark (`docs/benchmarks/browseros/`) and a by-area index of all commits since 6e4c6c5.
  Licence is applied (FSL-1.1-ALv2, user commit 3c68fca).

- **Typed decide, run_script (codemode + RLM), summarise_parts, Auto (2026-10-31; d2a69f3..acae8ab):**
  - Backend `src/decide.zig`: `POST /v1/aux/decide` (JWT or sk-eai key, `X-EveryAI-Session`) `{job?, text, instructions?,
    questions:[{id, kind: bool|choice|score, prompt, choices?}]}` → `{answers:[{id, value}], model, charged_micros}`;
    value or "unsure" (never `p`); strict json_schema, bad replies → unsure; usage kind `decide`. Internal
    `decide.decide(...)`. Env `AUX_DECIDE_MODEL`, `AUX_SUMMARISE_MODEL`.
  - Chat `summarise_parts {url, question}` (`src/summarise.zig`): ~12K parts, decide scores, top 12 (+unsure, ≤24)
    summarised 6 at a time, merged with `[part N]`; `tool_status` progress; usage kind `summarise`.
  - Auto (`src/auto.zig`): `model: everyai/auto` decides mode/rich/tier before the turn, SSE `route {model, mode,
    tools_enabled}` first; `AUTO_FAST|BALANCED|BEST_MODEL`; listed first in `/v1/models`. App: picker entry, `RoutePart`
    chip "Auto · Search · Sonnet 5.5" with re-run; usage labels Decisions / Long reads; `core/api/decide_client.dart`.
  - Code `run_script` (`harness/everyai/script_io.dart`): TypeScript in Deno with no permissions; stdin/stdout bridge
    readFile/grep/glob (project only, no secrets), webFetch/webSearch, decide/rank, llmQuery (utility model; `script:
    true` = depth 2). Read-only (`ScriptAction`), no approval. Caps per tier in `settings/script_caps.dart` (`ScriptCaps`
    on `SessionSpec.script`); Claude/GPT/Gemini by default; Settings → Code → Scripts. Deno 2.9.8 via
    `tool/fetch_deno.sh` / `DENO_BIN`. Transcript `_ScriptView`.
  - Compaction: Thorough+ asks decide which old tool outputs the work still needs; those are cleared last.
  - Bug fix: decide checks a no-`expect` repro shows this bug ("other" refused); verify refuses changed repro tests/scripts
    (snapshot at reproduce, additions allowed, or after asking the user); phase notes point at run_script and git bisect.
  - Approval risk label (`code/approval_risk.dart`, informational only).
  - zig tests pass (96 unit, 55 integration); flutter analyze clean, full flutter test passes. Nothing live-tested.

- **OpenHands removed, Deno bundled, quick wins (2026-10-31; 0890207..7da3ddf):**
  - c9b1cb8 removes the OpenHands harness, sidecar, facade, `CodeHarnessKind`, tier cap, fetch/bundle scripts and their
    tests; `HarnessError` is in `harness/harness.dart`; `code/sample/` holds `createSampleProject`; agent_eval keeps
    `scenario_test.dart` on the EveryAI harness. 178c40a: `macos/scripts/bundle_deno.sh` puts Deno in
    `Contents/Resources` (signed; `deno.entitlements` JIT).
  - Chat: starter chips switch mode (`chat/domain/starters.dart`), backend titles after the first reply
    (`chat/data/chat_titles.dart`, `ChatRepository.renameIf`), `/model` opens the picker, account row from `/v1/me`
    (`auth/profile.dart`), risk label carries the session.
  - Harness: `.everyai/plans/` saved plans and `.everyai/memory.md` + `memory` tool (`project_notes_io.dart`, loaded
    into new sessions' prompts; tracked files ignored), third identical call not run, `max_tokens` fitted to the window.
  - flutter analyze clean, 732 tests pass. Not live-tested. 4 empty commits await the user's OK to drop (TODO.md).

- **No-env run (2026-10-31, d5fd061):** `JWT_SECRET` optional in development (random per run), `OPENROUTER_API_KEY`
  optional (`App.keyless`; chat 400 `no_api_key`, gateway 401, client's own no-key reply; catalog fetched without a
  key; dev credits only with a server key). App banner "Add API key". A fresh clone needs only `scripts/dev.sh` and a
  key pasted in Settings → API keys (verified: binary started from an empty folder with `env -i`).

- **Max/Ultra review fixes (2026-11-03; 3354750..597fbf7)**, from an adversarial review of the flows:
  - `PhaseFlow` tracks background forks by child id (`forks`); build waits for them; the turn end that finishes verify
    adds a Done note. Research needs one finished report and none still running (refused/failed don't count).
  - Second task: a message after done goes to the decider (job `flow`, `new_task`); a new task restarts the flow
    (`restart()`, new `run` id, approved plan cleared). Ultra workers are `research-<run>-N`, tracked per run.
    Max ↔ Ultra mid-flow keeps the phase (`withUltra`). A user message resets nudges.
  - Gates: `apply_patch` checked per file (harness `patchPaths`, app `writeTargets`); MCP asks before the plan even in
    Full auto (`decideAll(askMcp:)`); report fences defused.
  - Long runs: unreported background forks re-watched after restart (`unreportedBackground`); Ultra workflow 6 at once,
    45 min timeout, fallback angles, failed workflow → stuck until the user writes; Ultra cap on credits too; phase
    note after compaction and at the step cap.
  - Quick builds: decider `build_now` jumps to build (`buildingUnplanned`); present_plan allowed from questions; prose
    answers move questions on; research prompt sees model prices and sizes small tasks small.
  - Planning: gh reads are read-only; `isPlanningShell` (git fetch/pull --ff-only, curl/wget to stdout, tool
    inspection) runs before the plan and asks in Plan mode.
  - Bug fix: verify passes when the marker is gone / exit 0 / only another failure remains; repro snapshot only the
    tests the repro touches; `bug_check review` asks `SessionSpec.reviewModel` (another vendor) with
    `bugReviewSystem`. `/btw` uses the session's model.
  - 747 flutter tests pass, analyze clean. Not live-tested; no controller-level test of the Ultra queue/timeout.

- **Multi-harness run 1: foundations (2026-11-04; merge e721343, then 6d0d528).** Plan `~/.claude/plans/multi-harness.md`,
  notes `docs/research/batches/multi-harness/run1/`. `features/code/drivers/`: `HarnessDriver` (info, caps, detect,
  models), `driver_policy.dart` fallbacks, `driver_registry.dart` (everyai, claude-code and gemini need consent, codex,
  opencode, acp:<cmd>, terminal:<cmd>; the outside ones are stubs until run 2), `driver_process` (EVERYAI_SESSION,
  driver roots in the process table, `closeAllDriverProcesses`), `json_rpc.dart`, `event_journal.dart`,
  `UsageReport` (plan usage in `UsageTotals.planMicros`), `SessionSpec.briefing`; replay kit
  `test/support/replay_transport.dart`. `features/code/host/`: a loopback MCP server, with tokens per session, idle
  expiry, and `HostTools` (not wired yet). `drivers/briefing/`: skill export per session, `sessionBriefing`, and
  recipes for each CLI. 832 tests pass. Run 2 (drivers + Stage 2) is in progress on `batch/mh-2`.

## Next steps
0. **User testing of the 2026-10-30 build pass** (live and click-through), then re-enable the eval gate. Open/skipped items are in TODO.md (backend MCP client, OAuth, connectors, resvg, skill review, App Store variant, Win/Linux).
0. **Every harness in one workspace** (`TODO-multi-harness.md`, plan `~/.claude/plans/multi-harness.md`): Stages 1–2
   are being built (run 1 merged, run 2 running). Claude Code and Gemini sit behind a consent setting until the owner's ToS check.
   EveryAI harness upgrades are in `TODO-harness.md` (split from TODO.md 2026-11-04).
1. **Current plan (`~/.claude/plans/few-tasks-in-your-parsed-piglet.md`)**: §1–3 bug fixes done; next §4 tiered agent models (`/v1/agents`, effort), §5 git worktrees (App Support, squash merge), §6 agent evals, §7 `docs/CODE_ROADMAP.md`.
1. **Phase B, the Code workspace** (desktop; see the plan file for the full spec):
   1. ~~Harness + FakeHarness~~ and 2. ~~transcript, session view, question cards~~: done (c531059).
   3. Projects (open/clone/new) and the git service (worktree per session, diff/hunks, checkpoints).
   4. Panes: Diff, Terminal (xterm + flutter_pty), Processes, Preview (reuse `flutter_inappwebview`).
   5. ~~The sidecar~~: done (dev mode; bundling into the app is in TODO.md).
0. **User's next requests (TODO.md "Requested, not started")**: token/cost meter and context ring in Chat and Code, usage tracker in Settings, file uploads in Chat and Code (grey out unsupported), remote-host coding sessions.
2. **Phase C leftovers:** see "Still missing" in the progress log above.
3. **Backend:** native provider adapters later; Stripe keys (TODO.md).
4. Write `docs/ROADMAP.md` (moat) and keep TODO.md updated.

## Gotchas
- Format Dart with `dart format -l 120 <files>` (the project's width). Plain
  `dart format lib` rewraps every file to 80 columns.
- Zig 0.17: `**` array repetition is gone (use `@splat` + concat);
  `std.ArrayList` is unmanaged; handlers need `(*App, *anole.Request)`
  params even when unused.
- Anole `testing.Response.json(T)` takes no allocator; the test client type is
  `anole.testing.Client(anole.Server(App))`.
- `anole.client(req).fetch(url, .{.method = .post, .headers = &.{.{k,v}},
  .body})` is the convenience client. The core `http.fetch` is for streaming
  (`.stream = true`).
- OpenRouter: with native web search, citations are nondeterministic; `exa`
  always cites (~$0.007/search). The usage chunk comes last, before
  `[DONE]`; `: OPENROUTER PROCESSING` comments occur.
- The old FastAPI backend on :8000 is no longer needed; backend-exp runs on :8080.
