# Hermes Agent (Nous Research): what it does and what EveryAI should take

- **Repo:** https://github.com/NousResearch/hermes-agent (about 258k stars, "The self-improving AI agent built by Nous Research")
- **License:** MIT, "Copyright (c) 2025 Nous Research" (`LICENSE:1-3`)
- **Researched commit:** `903230b1e23e0c496b28e5d2e8c4f2639cd506b6` on untagged `main` (2026-10-30, "fix(plugins): doctor stages only the plugin it validates"). Newest remote tag is v2026.9.24.
- **Companion repo:** `NousResearch/hermes-official-plugins` (MIT) at `1e326dd` (memory-wiki, agent-importers, homeassistant, camofox). Only listed, not read.
- **Date:** 2026-10-30. Clones are in `/private/tmp/claude-501/hermes-research/`.
- **Companion doc:** `docs/research/opencode-agents.md` (opencode, MIT). Comparison blocks below refer to its sections.
- **Citation format:** `path:lines` relative to the Hermes clone root unless a prefix says otherwise. Docs live in `website/docs/`.

**How to read the evidence.** Source-level claims (code constants, config defaults) are marked by a code path. Claims that rest only on `website/docs/` or `plugin.yaml` are called "documented". The docs are not reliable on their own: `prompt-assembly.md` contradicts the code on which tier holds the skills index (the code is authoritative: `agent/system_prompt.py:738-813`). Section 8 lists what was not verified.

---

## 1. Executive summary: the 10 most valuable ideas for EveryAI

Ranked by value to EveryAI after de-duplicating overlapping suggestions across the topics (see section 6 for the merged roadmap). "Fits in OpenHands" means implementable in the Flutter/Zig layers without changes inside the sidecar.

| # | Idea | Impact | Effort | Where it lives |
|---|------|--------|--------|----------------|
| 1 | Recover from `finish_reason=length`: never execute a truncated tool call, re-issue it with a bigger cap, continue cut-off text with a nudge, and force a tool-less summary when the step budget runs out (`agent/turn_truncation.py`, `agent/chat_completion_helpers.py:2279-2330`). | high | small | `backend-exp/src/chat.zig`, `gateway.zig` (our layer) |
| 2 | One command-safety policy for Code: an unconditional hardline floor plus enforced `permissions.deny/allow`, a dangerous-pattern classifier, and once/session/always approvals that never match compound commands. Merges three overlapping topic recommendations (`tools/approval.py`, `approval_floors.py`, `approval_detection.py`). | high | medium (needs a prototype, see 6.2) | Flutter `features/code/domain/` |
| 3 | A fixed denial template for the model: "The user has NOT consented... do NOT retry, rephrase, or reach the same outcome another way", with the user's reason appended verbatim and distinct outcomes for denied / timed out / cancelled (`tools/approval.py:694-775`). | high | small | Flutter (`agent_mode.dart`, `deny()` in `code_providers.dart`) |
| 4 | SSRF and untrusted-content handling for `web_fetch`: block private/loopback/metadata addresses with connect-time IP checks, wrap results in `<untrusted_tool_result>` with delimiter defanging (`tools/url_safety.py`, `agent/tool_dispatch_helpers.py:447-480`). This is a real server-side hole in our own backend. | high | medium | `backend-exp/src/chat.zig` `webFetch`, `tools.zig` |
| 5 | Chat memory: two small hard-capped files (agent notes 2200 chars, user profile 1375), one `memory` tool with atomic batch ops, frozen into the prompt at conversation start so the cache stays intact (`tools/memory_tool.py`, `tools/memory_tool_store.py:29-33`). Plus `session_search` over our existing local FTS5 table as a UI tool. | high | medium + small | Flutter + `tools.zig` |
| 6 | Cache-safe context delivery: never edit the system prompt mid-session; deliver changes as a note on the next user message (skills delta, surface switch, mode note) (`agent/surface_switch.py`, `agent/skills_index_delta.py`). EveryAI already does this for modes; generalize it. | medium | small | Flutter `modeNote` generalization |
| 7 | Project instruction files loaded by us, not by the persona text: one type wins, `AGENTS.override.md` first, injection scan, size cap, plus lazily discovered nested hints appended on first touch (`agent/prompt_builder.py:1580-1760`, `agent/subdirectory_hints.py`). Check first whether OpenHands already loads these (it likely does). | medium | medium | Flutter, only if OpenHands does not |
| 8 | A one-table cheap-model routing config (Hermes `auxiliary.*` slots: compression, approval, review, voice_chat, curator, goal_judge, background_review, title_generation, ...) (`hermes_cli/config_defaults.py:750-800`). This maps directly onto `/v1/agents` and the gateway. | medium | small | `backend-exp/src/agents.zig` |
| 9 | Skills as `SKILL.md` folders with a compact index in the prompt and progressive loading; later a staged-for-approval post-session review. Needs a cost and consent decision first (section 8). | high | medium (library) / large (review loop) | Flutter + gateway; library may already exist in OpenHands |
| 10 | Eval-gated prompt blocks. Hermes ships `evals/` (compaction recall, tool_search, prompt_footprint, token_accounting, ...) and states the reason and eval next to prompt text. Adopt as a rule for `tool/agent_eval`. | medium | small | process, `tool/agent_eval/` |

Explicitly **not** recommended (section 6.4): wake word, GPT-Live, profile distributions, managed scope / remote config plane, cloud terminal backends (Modal, Daytona), Kanban, external memory providers (Honcho and others), messaging bridge and pairing codes for now.

---

## 2. Architecture overview

- **Language and packaging:** Python 3.11-3.14 with uv and an in-house PM (`pm/`). TypeScript for the Ink TUI (`ui-tui/`), the Electron desktop app (`apps/desktop/`) and the dashboard (`web/`).
- **Entry points** (`pyproject.toml`): `hermes = hermes_cli.main:main`, `hermes-agent = agent.legacy_cli:main`, `hermes-acp = acp_adapter.entry:main`. REPL: `cli.py`. Messaging gateway: `gateway/run.py` (`GatewayRunner`). TUI/Desktop backend: `tui_gateway/server.py` (JSON-RPC).
- **Agent loop:** `run_agent.py` (AIAgent facade), `agent/agent_init.py` (construction), `agent/conversation_loop.py` (`run_conversation`), phases in `agent/turn_*.py` (`turn_context`, `turn_iteration_prep`, `turn_api_call`, `turn_tool_round`, `turn_finalizer`). Tools run through `agent/tool_executor.py`.
- **Tool execution:** a batch of tool calls is split into ordered parallel and sequential segments. Parallel worker cap is `_MAX_TOOL_WORKERS = 8` (`agent/tool_executor.py:135`). `clarify` and a few UI tools are never parallel; read-only tools such as `read_file` are in a parallel-safe set (`agent/tool_dispatch_helpers.py:30-36`).
- **Tool registry:** each `tools/*.py` calls `registry.register(name, toolset, schema, handler, check_fn)` at import (`tools/registry.py:1-6`); `model_tools.py` exposes `get_tool_definitions()` and `handle_function_call()`; `toolsets.py` holds the bundles. There is a deferred-tool path (`tool_search` / `tool_describe` / `tool_call` bridges, config near `hermes_cli/config_defaults.py:1972-2002`, evals in `evals/tool_search/`) so large tool sets do not bloat every prompt.
- **Extension system:** `plugins/` holds platform adapters, browser, computer_use, context_engine, cron_providers, config_backends, dashboard_auth, delegation, disk-cleanup, kanban, memory, model-providers, security-guidance, web. `plugins/plugin_loader.py` loads them and a `plugin-catalog/*.yaml` lists community ones. Design rule in `AGENTS.md`: new capability should arrive as plugins, skills or CLI commands, not new core tools.
- **Provider and credential layer:** `providers/`, `plugins/model-providers`, and `agent/credential_pool.py` ("Persistent multi-credential pool for same-provider failover"). Pool selection strategies: `fill_first`, `round_robin`, `random`, `least_used` (`agent/credential_pool.py:118-126`), per-model cooldowns (`agent/credential_pool_model_cooldowns.py`). Side tasks go through one auxiliary client router: main provider, then OpenRouter, Nous, custom endpoint, native Anthropic, direct providers; HTTP 402 falls through the chain (`agent/auxiliary_client.py:1-10`).
- **Cost and usage:** `agent/usage_pricing.py`, `agent/billing_usage.py`, `agent/account_usage.py`, `agent/insights.py` (`/insights`), `agent/rate_limit_tracker.py`, `agent/auxiliary_rate_limit_backoff.py`. Not read in detail.
- **Cache rule:** the prompt cache must never break mid-conversation. Memory and skill writes take effect next session.
- **State:** `~/.hermes/` (profile-scoped under `~/.hermes/profiles/<name>/`): `config.yaml`, `.env` (secrets only), `state.db` (SQLite, WAL, FTS5), `memories/`, `skills/`, `checkpoints/`, `logs/`.
- **Code layout quirk:** big modules are a facade plus `<stem>_<topic>.py` siblings. Grep the siblings.
- **Evidence tooling:** `evals/` has about 50 entries including `compaction/`, `tool_search/`, `prompt_footprint/`, `provider_fallback/`, `token_accounting/`, `readtool/`, `toolperf_abeval/`, `prefix_rediet/`. `evals/compaction/README.md` describes a recall-vs-tokens harness: generate factual questions from the region that will be summarized away, compact under each policy, ask a fresh model with only the post-compaction context, and score against gold. Results were cited but not read.

---

## 3. Topics

Each topic gives: how Hermes does it (citations, short quotes), how EveryAI does it today, recommendations. Topics also covered by `opencode-agents.md` get a "Hermes vs opencode" block. EveryAI-side statements about OpenHands 1.59 are **unverified** unless stated: OpenHands ships AgentSkills/microagents (`.agents/skills`), a condenser and a stuck detector, so several "gap" claims below may already be covered by the sidecar. Check before building.

### 3.1 Self-improving skills

**How Hermes does it**

- **Format.** A skill is a directory with `SKILL.md` (YAML frontmatter + markdown) and optional `references/`, `templates/`, `scripts/`, `assets/`. Frontmatter: `name` (lowercase-hyphen, max 64), `description`, `version`, `author`, `platforms`, `metadata.hermes.*` (`skills/AGENTS.md:1-40`, `tools/skill_manager_tool.py:109-171`). Authoring rule: description at most 60 characters, one sentence ending in a period; body order When to Use, Prerequisites, How to Run, Quick Reference, Procedure, Pitfalls, Verification. Telemetry (use/view/patch counts, state, pinned, created_by) sits in a sidecar `.usage.json`, not in frontmatter (`tools/skill_usage.py:1-8`). Precedence: project (`.hermes/skills`, `.agents/skills` in a trusted git root) > local > `skills.create_dir` > `skills.external_dirs`. The repo seeds 44 bundled skills and 149 optional ones (counts from the scout, not recounted).
- **Progressive disclosure.** The prompt holds only an `<available_skills>` index (category, name, 60-char description) with a forceful rule: "If a skill matches or is even partially relevant to your task, you MUST load it with skill_view(name)" (`agent/prompt_builder.py:1233-1320`). Levels: `skills_list`, `skill_view(name)`, `skill_view(name, file_path)` (`tools/skills_tool.py:613-745`). New skills mid-conversation are announced in a note on the next user message and join the index at the next compaction, to protect the cache (`agent/skills_index_delta.py`).
- **Single write tool.** `skill_manage` takes an operations array (create, patch, write_file, remove_file, delete), atomic with rollback on any failure, per-action JSON-schema branches with `additionalProperties:false` (`tools/skill_manager_tool.py:837-943`). Hard checks: name regex, frontmatter, 1024-char description cap, 60-char prompt budget on new descriptions, 100k content cap.
- **Triggers.** (1) A one-line prompt hint. (2) A counter of tool-calling iterations that triggers a review every `agent.skills.creation_nudge_interval` (default 10): `agent/agent_init.py:1288` (`int(_agent_cfg.get("skills", {}).get("creation_nudge_interval", 10))`). The memory nudge is a separate counter at `agent_init.py:1213-1220` (default 10). (3) A post-turn background review: a forked agent on the same provider, model and cached prefix, with a tool whitelist (skills and memory toolsets plus `read_file`, `search_files`), a 16-iteration cap, an input-token budget, cancelled when a live turn starts (`agent/background_review.py:1-8,165-182,1092-1125`; trigger in `agent/turn_finalizer.py:833-862`). Config slot `auxiliary.background_review` (`hermes_cli/config_defaults.py:798`): "auto" replays the full conversation on the main model for a warm cache; another model replays a compact digest ("~3-5x cheaper"); an explicit `max_input_tokens` caps the summed replay input.
- **The review prompt.** "Be ACTIVE - most sessions produce at least one skill update"; target shape is class-level umbrella skills with `references/`; a do-not-capture list (environment-dependent failures, negative claims about tools, transient errors, one-off narratives, unresolved failures); preference order: patch a skill loaded this session, patch an umbrella, add a `references/` file, create a new class-level skill (`agent/background_review.py:393-585`).
- **Write guards.** In a review fork, patching an existing file is refused unless `skill_view` loaded that exact file in the same run (`tools/skill_manager_guards.py:34-70,164-252`). Origin is tracked in a ContextVar (`tools/skill_provenance.py`). Autonomous deletes are refused for pinned, external, bundled and hub skills; the curator must supply `absorbed_into` pointing at an existing skill (added after a bug where an LLM archived clusters with no verified consolidation). An advisory linter (`tools/skill_linter.py`) flags incident-log-shaped bodies, oversize (24k chars), references sprawl (60 files). Optional regex scan `skills.guard_agent_created` (default off).
- **Ledger and rollback.** Every mutation by any actor appends a JSONL entry to `~/.hermes/skills/.curator_ledger.jsonl` with before/after manifests and content-addressed blobs under `~/.hermes/.curator_backups/blobs/`; `hermes curator rollback <id>` restores one edit and fails closed if its own safety capture fails (`tools/skill_ledger.py:1-60`). Tar.gz snapshots before curator runs (`agent/curator_backup.py`).
- **Approval gate.** `skills.write_approval` (default false) stages every write under `~/.hermes/pending/skills/`; `/skills pending|diff|approve|reject` (`hermes_cli/config_defaults.py:1455-1469`, documented in `user-guide/features/skills.md:668-704`). Memory has the same gate.
- **Curator.** Runs after `interval_hours` (168) when the agent has been idle `min_idle_hours`; touches only `created_by: agent` skills. Deterministic pass: active, stale after 14 days, archived after 30 days into `.archive/`, never deleted. Optional LLM consolidation (`curator.consolidate`, default false) merges narrow skills into umbrellas, "DO NOT delete any skill" (`agent/curator.py:209-420,881-1000`, `hermes_cli/config_defaults.py:1480-1500`).
- **User-directed.** `/learn` builds a prompt and sends it as a normal turn; source can be a directory, URL, the conversation, or notes (`agent/learn_prompt.py:1-60`). Skills Hub installs from GitHub taps, skills.sh, ClawHub and URLs with a trust-tiered scan (`tools/skills_guard.py`).

**EveryAI today.** No skills concept (grep of `frontend/lib` and `backend-exp/src` finds nothing). The Code persona and `workingRules` are constants (`frontend/lib/features/code/settings/agent_prompt.dart`), layered `instructions` are hand-written. Whether OpenHands 1.59 loads `.agents/skills` natively is unverified, and the reviewer notes it likely does.

**Recommendations**

1. **Check OpenHands native AgentSkills first**, then put a `SKILL.md` library (project and user tiers, 60-char descriptions, compact index, frozen per session) on top only if it is missing. If a client tool is needed, `skill_view` as a client tool works like `ask_user_question`. (impact high, effort medium)
2. **Shape rules and a deterministic validator** (frontmatter, name regex, 60-char description, body cap, references cap, lint for PR-number density and "fix-X" names). Pure Dart plus prompt text. (high, small)
3. **Post-session review proposing skill edits, staged for approval.** Not "same cached prefix": the review would be a separate gateway request with its own cache cost, and OpenHands owns the conversation prefix. It is only cheap when the transcript is small or the model is a cheap one with a digest. The review costs real tokens (a code comment cites roughly 30K per event, unverified), and EveryAI bills at cost x1.15, so this needs a consent and budget decision first (section 8). (high, large)
4. **Ledger with sha256 blobs and rollback**, with read-before-write enforced in our own review controller. It cannot be enforced inside OpenHands tool calls, so apply it only to skill edits our app performs. (medium, medium)
5. **Usage sidecar plus a deterministic stale/archive pass** for agent-created skills only; defer LLM consolidation. (medium, medium)
6. **`/learn`** as a prompt-only command in the composer and "Save as skill" in Chat. (medium, small)
7. **Import** from `~/.claude/skills` and `.agents/skills` (same SKILL.md format). (low, medium)

### 3.2 Multi-platform integration (gateway)

**How Hermes does it**

- One long-lived gateway process hosts platform adapters. Adapters are plugins (`plugins/platforms/<name>/adapter.py` + `plugin.yaml`) that subclass `BasePlatformAdapter` (`gateway/platforms/base.py:1808`) and register through `gateway/platform_registry.py`, so a new platform needs no core change (`gateway/platforms/ADDING_A_PLATFORM.md:1-80`). The directory lists about 27 platforms (count from the directory listing; adapter internals not read).
- **Session keys.** `SessionSource` carries platform, chat_id, chat_type, user_id, thread_id, scope_id. `build_session_key` is "the single source of truth" mapping it to a deterministic key; DMs by chat, groups per participant only if configured, threads shared by default, WhatsApp JID/LID aliases canonicalised (`gateway/session.py:69-110,691-731`).
- **Per-session source context** in the system prompt marks chat names and topics as untrusted metadata, and in shared multi-user sessions prefixes each message with `[sender name]` instead of pinning a name in the cached prompt (`gateway/session.py:172-181,383-445`).
- **Auth.** Default-deny allow-lists; DM pairing: an 8-character code from an unambiguous alphabet via `secrets`, salted SHA-256 stored with chmod 0600, 1 hour expiry, 3 pending per platform, one request per user per 10 minutes, lockout after 5 failures, approved from the CLI (`gateway/pairing.py:1-40,475-500`).
- **Rich output.** The model writes `MEDIA:<path>` in text; `extract_media()` masks code blocks and quotes so example paths are never uploaded; directives `[[audio_as_voice]]` and `[[as_document]]` select the sender (`gateway/platforms/base.py:3202-3330`).
- **Cross-platform hand-off.** `send_message` tool, a channel directory cached in `channel_directory.json`, and `mirror_to_session` which writes a "delivery-mirror" record into the target session so the receiving agent knows what it was sent (`gateway/mirror.py:1-60`).
- **Cron.** A 60 s tick under a file lock; `next_run_at` advanced before dispatch for at-most-once; a wake-gate script printing `{"wakeAgent": false}` skips the LLM run; the prompt says answer exactly `[SILENT]` to suppress delivery (`cron/scheduler_prompt.py:15-30,268-285`).
- **Busy input.** `busy_input_mode: interrupt | queue | steer`; `/stop`, `/approve` bypass the queue to avoid deadlocking approval waits (`gateway/AGENTS.md:15-24`, `hermes_cli/config_defaults.py:817`).

**EveryAI today.** None of this. Chat is local-only (Drift), the Code workspace is a desktop sidecar, and the `/v1/chat/completions` gateway only serves OpenHands. History local-only is a recorded user decision.

**Recommendations** (all below are medium-to-large and several conflict with the local-only decision; ask the user before any bridge work)

1. Scheduled agent runs with a `[SILENT]` / wake-gate contract and OS notifications. Undefined today: where results land when chat is local-only and there is no sync. Needs a design decision before sizing. (high value, effort large)
2. A `MEDIA:<path>`-style directive so the model emits a path and the client chooses the native renderer; fits Code outputs into chat attachments. (medium, small)
3. A "Current session context" block marked untrusted, with per-user prefixes outside the cached prompt, if sessions ever carry source info. (medium, small)
4. Busy-input mode as a persisted setting with bypass commands for stop/approve. (low, small)
5. Messaging bridge with pairing codes and a deterministic session-key function: **defer**. The session-key function is over-engineered with no multi-platform ingress, and a bridged chat needs server-side transcripts, which conflicts with local-only history. (large)

### 3.3 Browser and terminal actions

**How Hermes does it**

- **Terminal.** Each call spawns a fresh `bash -c`; env/functions/aliases are snapshotted once and re-sourced, cwd persists via a temp file or stdout markers (`tools/environments/base.py:1-12,312-330`). Backends: local, docker, ssh, modal, managed_modal, daytona, vercel_sandbox, plus plugin backends (`tools/environments/`). Dangerous-command checks are skipped on container backends because the container is the boundary, except Docker with host bind mounts (`tools/approval.py:1051-1067`). The tool description tells the model to use file tools instead of `cat/grep/sed` and that output is auto-truncated (`tools/terminal_tool.py:165-190`).
- **Output cap and spill.** Head+tail window, default 50,000 chars (`tool_output.max_bytes`, `hermes_cli/config_defaults.py:542`); the full raw output is written to a file that is ANSI-stripped and secret-redacted before exposure; the result carries `full_output_path` and tells the model to page it with `read_file`/`search_files` (`tools/terminal_tool_result.py:170-195`).
- **Background processes.** `tools/process_registry.py`: 200,000-char rolling buffer, poll/log/wait/kill, crash checkpoint `processes.json`, `notify_on_complete`, and `watch_patterns` for rare signals that demote to completion notices when noisy (`:1-4,59-80,802-885`).
- **Browser.** One core tool, `browser_exec`, takes model-written Python against CDP helpers from the `browser-harness==0.1.13` engine (`tools/browser_use_cli.py:895-1043`). No fixed click/type schema; structure from `page_info()`, DOM `js()` or an accessibility-tree call. Screenshots attach only if the model has vision, and the tool description is rebuilt per model capability. Session precedence: CDP override, local sidecar, cloud provider, consented real-profile copy, Lightpanda, packaged Chromium (`tools/browser_session.py:1-50`). A browser vault fills saved logins without secrets entering the conversation.
- **Delegation, execute_code, file tools.** Covered in 3.6 and 3.9. `execute_code` is programmatic tool calling over RPC (`tools/code_execution_tool.py:1-30`). The `patch` tool uses an ordered chain of fuzzy match strategies (`tools/fuzzy_match.py:1-30`).
- **Desktop pane bridge.** In desktop sessions the agent can read the GUI's own terminal pane via a blocking request/response (`tools/read_terminal_tool.py:1-9`).

**EveryAI today.** Code runs on OpenHands: `terminal`, `file_editor`, `task_tracker`, plus client tools. No agent browser. Panes (Terminal, Processes, Preview) are planned. How OpenHands truncates terminal output is unverified.

**Hermes vs opencode.** opencode truncates tool output at 2,000 lines or 50 KB and saves the rest to a file with a "Full output saved to" hint (`opencode-agents.md` summary item 9). Hermes does the same at three layers (per-tool cap, spill at 100K chars with a 1,500-char preview, 200K per-turn budget; `tools/tool_result_storage.py:1-60`, `tools/budget_config.py:1-30`) and also redacts the spilled file. Both agree on the pattern; neither is reachable from the Flutter client for OpenHands terminal output.

**Recommendations**

1. **Command policy and approvals: see 3.9** (merged). (high)
2. **Spill-to-file.** The OpenHands tool result cannot be rewritten from the client after the fact. Options: a `workingRules` instruction (weak), or gateway truncation, which does not see terminal output because that goes sidecar to app. Treat feasibility as **low** for terminal output; it is feasible for our own server tools such as `web_fetch` (truncate with a marker, cap in `chat.zig`). (medium value, feasibility low for Code)
3. **Background process registry as a client tool** (`run_background` served by the app via `flutter_pty` / `Process.start`) with a ring buffer, poll/kill and a completion message. It doubles as the data source for the Processes and Terminal panes. (high, large)
4. **Agent-visible preview**: `preview_eval`, `preview_screenshot`, `preview_navigate` as client tools served by the Preview webview, with an image part only when the model accepts images. Lets the agent verify its own UI work. Skip cloud browsers and real-profile logins. (high, large)
5. Design `SessionSpec` with `backend` and `hostAccess` fields so a future remote harness can relax checks in true sandboxes. Do not build backend matrices. (low, small)

### 3.4 Voice integration

**How Hermes does it**

- **Two modes** (`voice.voice_chat_mode`): `chained` (STT, a normal turn, TTS) and `gpt-live` (a full-duplex OpenAI front end that delegates all real work to Hermes). `gpt-live` exchanges SDP server-side so keys stay off the client, runs on the user's own OpenAI key (the Nous proxy does not carry it), and is cited at $0.05/min from a code comment (`tools/voice_live.py:1-186`).
- **Voice-turn note.** Voice-originated turns get a per-turn note on the user message (possibly mis-heard transcript, short plain sentences, no markdown/lists/code/URLs), kept out of the system prompt for caching. A barge-in latches `[Note: the user interrupted your previous spoken reply before it finished.]` (`tools/voice_live.py:60-80`, `tools/tts_streaming.py:46-66`).
- **Fast-model route** `auxiliary.voice_chat`: a voice turn may use a cheaper model only if the conversation still fits under that model's compression threshold; otherwise it stays on the main model rather than compacting history to suit it (`agent/voice_turn_route.py:1-218`).
- **STT.** Dispatcher with local faster-whisper default and cloud fallbacks (`tools/transcription_tools.py:1-330`). Hygiene: language hint default `en`, VAD, a blocklist of known Whisper hallucinations ("thank you", "thanks for watching"), silence trimming, oversize chunking at silences (`tools/voice_mode_transcript.py:20-45`, `tools/transcription_chunking.py:1-60`).
- **Inbound voice notes.** Transcript is injected as a plain quoted line with no meta wrapper, because "The user sent a voice message..." made the model comment on voice mode; empty transcripts become a sentinel telling the model not to guess; failures never carry setup advice (`gateway/run_inbound_transcription.py:1-187`).
- **TTS.** `text_to_speech` tool returns a `MEDIA:` path; Opus/OGG for voice bubbles (`tools/tts_tool.py:702-747`). A single deterministic spoken-script normalizer (drops code, URLs, emoji, expands units/currency, headings folded) is shared by every path (`tools/tts_text_normalize.py:1-300`). Streaming: a `SentenceChunker` plus a consumer with fallback to whole-file TTS and a never-speak-twice rule (`gateway/streaming_tts_consumer.py:1-239`).
- **Barge-in.** Adaptive noise-floor trigger, 0.5 s grace, transcripts more than 60% similar to the spoken text rejected as speaker bleed, whole-utterance stop phrases (`tools/voice_mode.py:1141-1349`; numeric multipliers come from comments/config, partially unverified).
- **Wake word** "Hey Hermes" (`tools/wake_word.py:1-60`): off by default.

**EveryAI today.** No voice. Only audio attachments (`input_audio`, mp3/wav) to audio-capable models (`frontend/lib/features/attachments/attachment.dart`, `chat_transport.dart:246`).

**Recommendations**

1. **Dictation**: mic button and `POST /v1/audio/transcribe` in the backend, billed through the ledger at x1.15, with the hallucination blocklist, language hint and empty-transcript sentinel. (high, medium)
2. **Read aloud** with a Dart port of the spoken-script normalizer and sentence chunker; OS TTS for the free tier. Rule for UI tools: say "I made a quiz", do not read the JSON. (high, medium)
3. **Voice-turn note and a `voice_model` route** with a context-fit check. (high, small)
4. **Audio attachments transcribed by default** unless the model accepts audio and the user opts in. (medium, small)
5. Hands-free loop with barge-in and echo guard, built on 1 and 2. (medium, large)
6. **Do not adopt:** wake word (desktop-only, hard in Flutter, privacy cost) and GPT-Live (needs `flutter_webrtc` and a direct OpenAI key, which breaks the "all billing through our gateway at cost x1.15" model).

### 3.5 Persistent memory and session artifacts

**How Hermes does it**

- **Curated memory.** Two files in `~/.hermes/memories/`: `MEMORY.md` (agent notes, 2200 chars) and `USER.md` (profile, 1375 chars). Frozen into the system prompt at session start; mid-session writes reach disk but not the prompt (`tools/memory_tool.py:1-6,373-400`, `tools/memory_tool_store.py:29-33,177-230`). When full, the add is rejected with the current entries shown and the model reissues one batch that frees room. Content is injection-scanned because it lands in the system prompt. Optional `memory.write_approval` stages writes (`hermes_cli/config_defaults.py:1298-1313`).
- **Memory vs skills routing** in the prompt: task knowledge goes to skills; memory only for facts true in every session; write "declarative facts, not instructions to yourself" (`agent/prompt_builder.py:195-246`).
- **Nudge and review.** `memory.nudge_interval` default 10 (`agent/turn_context.py:750-770`), then the forked background review (see 3.1). Review prompts forbid saving environment failures, tool negatives, transient errors and one-off narratives.
- **Session recall.** Everything goes to `~/.hermes/state.db` with FTS5 (plus trigram and CJK variants) (`hermes_state_fts.py:23-60`). `session_search` infers its shape from arguments (discovery, scroll, read, browse), makes no LLM calls, returns real DB messages, caps content at 2000 chars in read mode (`tools/session_search_tool.py:1-40,660-700`). Compression splits sessions along `parent_session_id`.
- **One external provider** via a `MemoryProvider` ABC (`agent/memory_provider.py:105-225`); recalled text is wrapped in a fenced `<memory-context>` block with a "NOT new user input" note (`agent/memory_context.py:169-185`).
- **Instruction files.** `SOUL.md` identity; project context loads exactly one type, first wins: `.hermes.md`, AGENTS.md chain, CLAUDE.md, `.cursorrules` (`agent/prompt_builder.py:1512-1530,1640-1665`). Nested files load lazily and are appended to tool results (`agent/subdirectory_hints.py:1-30`).
- **Plans and todos.** `/plan` saves `.hermes/plans/YYYY-MM-DD_HHMMSS-<slug>.md` (`agent/plan_prompt.py:1-40`); `todo_list` is in-memory per agent, re-injected after compression (`tools/todo_tool.py:1-30`).
- **Compaction.** Fixed section template (Goal, Constraints, Completed Actions, Active State, Blocked, Key Decisions, Resolved Questions, Relevant Files, Critical Context), "latest user message WINS" (`agent/context_compressor.py:255-300,603-670`). Details in 3.11.

### Persistent memory compared (table)

The Claude Code column comes from general knowledge of Claude Code, not from reading its source. Treat it as unverified context, not a finding.

| Aspect | Hermes (read in source) | Claude Code (unverified, general knowledge) | EveryAI today |
|---|---|---|---|
| Curated memory | Two capped files, 2200 + 1375 chars, one `memory` tool, frozen in prompt per session | `CLAUDE.md` files plus an auto-memory `MEMORY.md` index with topic files; grows without a hard char cap | None for agents |
| Who writes it | Agent tool, nudge every 10 turns, background review fork | Agent and user edit files | Nobody |
| When it reaches the prompt | Next session only (cache safe) | Loaded at session start | n/a |
| Full-history recall | SQLite FTS5 plus `session_search` tool | Transcript files and `/resume` | Local FTS5 `message_search` for the user's sidebar only, not callable by the model |
| Project rules | One type wins, nested hints appended to tool results | `CLAUDE.md` hierarchy | Persona tells agent to read AGENTS.md; OpenHands may load it itself (unverified) |
| Plans | `.hermes/plans/*.md` file via `/plan` | Plan mode plus plan files | `present_plan` card only, nothing on disk |
| Todos | In-memory, revisioned, re-injected after compaction | Todo tool | OpenHands `task_tracker` folded into a `PlanItem` |
| Compaction | Structured summary, deterministic fallback, cooldowns | Auto-compact | OpenHands condenser; Chat has none |
| Safety | Injection scan, optional write approval | User-visible files | n/a |

**Recommendations for memory**

1. **Chat memory**: two capped entries stores plus a `memory` UI tool executed locally; render a snapshot as a block after the constant system prompt on the **first request of a conversation** and keep it fixed. The snapshot must be stored per conversation (Drift) because `/v1/chat/stream` is stateless and the cache design requires identical bytes on later turns. Ship with a Settings > Memory viewer, per-entry delete, an injection scan, and an approval toggle. (high, medium)
2. **`session_search` as a UI tool** over the existing local FTS5 table. It fits the local-only decision because the app executes it and returns only requested snippets. (high, small)
3. **Code project memory** via the settings layers: a user-level file and a per-project `.everyai/memory.md` rendered once into the suffix, written through a client tool that shows an approval card. (high, medium)
4. **Post-turn memory review on a cheap model**: the same cost and consent issue as 3.1 recommendation 3. Do not enable by default. (medium, medium)
5. **Code session index** for "resume where we left off". (medium, medium)
6. **Persist accepted plans** as `.everyai/plans/*.md` (git-excluded) so they survive condensation. (medium, small)
7. Import `CLAUDE.md` and memory into EveryAI memory once. (low, small)

### 3.6 Agent modes and subagents

**How Hermes does it**

- **No persistent plan/build mode.** `/plan` is a one-turn prompt delivered as a normal user turn: plan only, write a markdown plan file, no edits (`agent/plan_prompt.py:1-71`). It is enforced by instruction, not permissions. Personas: `SOUL.md` identity and a `/personality` session overlay (`website/docs/user-guide/features/personality.md`).
- **`delegate_task`.** Children are fresh `AIAgent`s with isolated conversation and terminal, see only goal and context, and return only a final summary (`tools/delegate_tool_progress.py:148-219`). Children inherit the parent's toolsets minus a blocklist: `delegate_task`, `clarify`, `memory`, `send_message`, `cronjob_manage` (`tools/delegate_tool_toolsets.py:12-123`); the model cannot widen tools. Defaults from `hermes_cli/config_defaults.py`: `max_iterations` 250 per subagent (`:1348`), `max_concurrent_children` 10, `max_spawn_depth` 1 (flat; `MAX_DEPTH = 1` in `tools/delegate_tool_config.py:23`). Each extra depth level "multiplies API cost" per docs. The orchestrator role plus a literal depth note in the child prompt.
- **Background children.** A top-level call returns a handle and the result re-enters as a new message; completions are stored in `state.db` before delivery; a child running when the process dies is marked unknown and not resumed (`website/docs/user-guide/features/delegation.md:9-32,184-262`, documented). Steer appends to the child's last tool result at the next iteration boundary; stall detection by heartbeat, no wall-clock timeout by default (documented).
- **Cheap workers.** `delegation.model` / `provider` pins children to a cheaper model; unknown routes are errors, never silent fallback (documented).
- **Worktree isolation per child** (`delegation.worktree_isolation`, default off): `.worktrees/subagent-<id>` on branch `hermes-subagent/<id>`; removed only if clean with zero commits, else archived to `refs/hermes/archive/` (`tools/subagent_worktree.py:1-60`).
- **`/review`** pre-wired reviewer subagent; **`/goal`** standing objective with an auxiliary judge (`goal_judge` slot) and a turn budget of 20 (`hermes_cli/goals.py:1-35`). Kanban (durable multi-worker board) exists; skip it.

**EveryAI today.** Four enforced modes (Ask, Auto-edit, Plan, Full auto) with a quote-aware read-only classifier, mode notes on user messages, and `present_plan` / `ask_user_question` cards (`frontend/lib/features/code/domain/agent_mode.dart`, `shell_readonly.dart`). Subagents: none working (OpenHands `task` is removed because it breaks conversation create in 1.59.0). `backend-exp/src/agents.zig` exposes tiers and a `subagents` flag.

**Hermes vs opencode.** opencode's subagents are child sessions behind one `task` tool with depth 1, fresh context, own prompt and permissions, a `task_id` to resume, and background notification as a synthetic user message (`opencode-agents.md` item 4). Hermes is similar but adds a tool blocklist, a concurrency cap, steer/stop, and per-child worktrees. opencode's Plan mode re-asserts a reminder and sends an explicit "you have left Plan mode" message; Hermes has no persisted mode at all. EveryAI's enforced modes are stronger than both for a GUI.

**Recommendations** (merged; the old "four notes" on subagents and worktrees are one workstream)

1. **`delegate` client tool**: child = second OpenHands conversation (own gateway key, own worktree), returns a tight summary. This is **large**: child usage attribution, approvals bubbling into the parent card, session memory, and restart handling all need design. Do not rate it medium. (high, large)
2. Child permission derivation: children never get `ask_user_question`/`present_plan`, inherit the parent's mode (Plan parent gets read-only children). (high, medium, part of 1)
3. Flat depth, concurrency cap 3-4, one-shot cap for evals. (medium, small)
4. Cheap worker tier via `/v1/agents`, with explicit failure on an unknown route and shared session attribution. (high, medium)
5. Live subagent cards with Steer and Stop, and a stalled-child warning. (medium, medium)
6. `/review` and `/goal` later; both reuse 1. Budget `/goal` against the usage meter. (medium, large)
7. Adopt opencode's plan-reminder re-assertion alongside our mode note: re-insert the note after condensation. (medium, small)

### 3.7 System prompt assembly

**How Hermes does it**

- **Three tiers** joined stable, context, volatile (`agent/system_prompt.py:738-813`): stable (identity, guidance, coding brief), context (caller message, project files, workspace snapshot, platform hint), volatile (skills index, memory snapshots, plugin sections, profile line, date, runtime environment). Built once, cached on the agent, rebuilt only after compression.
- **Model-gated blocks.** Universal "Finishing the job" and parallel-tool blocks; `TOOL_USE_ENFORCEMENT_GUIDANCE` for gpt, codex, gemini, grok, glm, qwen, deepseek and others; an execution-discipline block for GPT-style models; none for Claude. A comment cites a 5-run A/B on Nemotron with no significant gain, so it was excluded (`agent/prompt_builder.py:344-560`). Lines naming absent tools are stripped.
- **Quote:** "NEVER substitute plausible-looking fabricated output ... Reporting a blocker honestly is always better than inventing a result." (`agent/prompt_builder.py:383-396`).
- **Coding brief and pinned workspace snapshot** (root, branch with ahead/behind, dirty counts, last 3 commits, manifests, verify commands), computed once per session (`agent/coding_context.py:84-131,535-600`).
- **Date line** has the date only, never a time (`agent/system_prompt.py`, `_timestamp_line`).
- **Mid-run steer.** A steer is a standalone user row after the newest tool results, wrapped in a self-describing marker `[OUT-OF-BAND USER MESSAGE - a direct message from the user, delivered once at this position; ...]`, with a system-prompt note that only that exact marker carries user authority (`agent/prompt_builder.py:562-612`, `agent/agent_runtime_helpers.py:3705-3745`).
- **Caching.** Up to four Anthropic breakpoints: system prompt (optionally split at the stable prefix) plus the last non-system messages; TTL 5m/1h/auto (`agent/prompt_caching.py:310-382`).
- **Prompt-bloat discipline**: comments such as "Ships in every cached prompt - keep tight."

**EveryAI today.** Chat has a constant prompt with breakpoints on the system prompt and last message (`backend-exp/src/tools.zig:23`, `chat.zig:139`); the gateway also marks the last tool. Code has `agentPersona` plus `workingRules` suffix and `<everyai-mode>` notes. No date, workspace snapshot, model-family gating or steer marker.

**Hermes vs opencode.** Both gate prompts per model family (opencode: GPT persistence rules, "assume the user wants code changes"; Hermes: enforcement blocks, none for Claude). opencode sorts tools alphabetically and puts breakpoints on the first two system and last two messages; Hermes up to four with a stable-prefix split. v2 opencode adds "treat new messages received during ongoing work as steering" to the prompt. Both treat mid-run messages as steering; Hermes also marks them as trusted.

**Recommendations**

1. **Pinned workspace snapshot** in the Code suffix, computed once at session creation and persisted so reconnects send identical bytes. (high, small)
2. **Steer marker plus a short prompt note.** True injection after the next tool result needs agent-server support for a message without interrupting, which is unverified and may not exist. Without it, only the marker and the note are possible; EveryAI's steer today interrupts and resends. (high value, depends on OpenHands)
3. **Model-family execution blocks**: do not inject into `gateway.zig` on Hermes's evidence alone. Injecting text into OpenHands requests changes the system message OpenHands builds and will fight its own prompt and the cache breakpoints the gateway already inserts. Evaluate with `tool/agent_eval` first, as Hermes did. (medium, medium)
4. "Finishing the job" and anti-fabrication paragraph in the persona. (medium, small)
5. Chat context tier after the cached prefix: date line, surface hint, with the breakpoint at the end of the constant part. (medium, small)
6. Generalize `modeNote` into `contextNote(kind, text)` for rules and settings changes. (medium, small)
7. A convention that every prompt block records its reason and eval. (low, small)

### 3.8 Custom agents, context files and settings

**How Hermes does it**

- **No agent-definition file format.** The custom-agent unit is a **profile**: a separate `HERMES_HOME` with its own config, `.env`, `SOUL.md`, memories, skills, sessions (`website/docs/user-guide/profiles.md`, documented). Shareable as "distributions".
- **Persona layers.** `SOUL.md` (global identity, never read from the project), `/personality` overlays (`agent.personalities`), and a manual `agent.system_prompt` (`hermes_cli/personality.py:1-80`, `agent/prompt_builder.py:1512-1560`).
- **Context-file discovery:** one type wins; per directory `AGENTS.override.md` > `AGENTS.md` > `agents.md`; deeper later; deduped; outside a git repo only cwd is read. Cap 20K to 500K chars (6% of window), head 70% / tail 20%, 5 s read timeout, injection scan blocking for repo files and warn-only for the user's own `SOUL.md` (`agent/prompt_builder.py:42-110,1033-1062,1580-1760`).
- **Config.** One YAML per profile plus `.env` for secrets; CLI flags on top; no project-level config file. Managed scope and a remote config plane exist for organizations (documented).
- **Protected instruction writes** to AGENTS.md, CLAUDE.md, SOUL.md, `.cursorrules` always ask, even in YOLO (`tools/file_tools_write_guards.py:179-280`).
- **Worktrees:** `.worktreeinclude` lists gitignored files to copy into new worktrees (documented).

**EveryAI today.** Layered JSON settings (user, project, local) with `instructions` and `agents` (types with description + prompt); `permissions.allow/deny` stored but not enforced; `<AGENT_TYPES>` lists names only; AGENTS.md left to the persona text and OpenHands.

**Hermes vs opencode.** opencode has real agent files (`.opencode/agents`), per-agent model/permission/prompt, an 8-level config precedence including managed and MDM, and a findUp for `AGENTS.md`, else `CLAUDE.md`, else `CONTEXT.md` (`opencode-agents.md` 2.3-2.5). EveryAI's agent types should follow opencode (file-defined, per-agent model and permissions), not Hermes (global delegation settings only).

**Recommendations**

1. **File-defined agents** (`.everyai/agents/*.md`, frontmatter model/mode/tools) only once a spawn path exists (3.6). Advertising types that cannot be spawned is dead UI. (high, large)
2. Load project instruction files ourselves **only if OpenHands does not** (verify first); add a scan and size cap and show loaded files as chips. (high, medium)
3. Nested hints on first touch: realistic only as a user-message note (`<everyai-hint path=...>`), since a tool-result append needs the sidecar. (medium, medium)
4. Named personas and custom instructions in Chat, appended after the constant prefix (`chat.zig:139`). (high, small)
5. Always-ask for writes to AGENTS.md / CLAUDE.md / `.cursorrules` / `.everyai/settings*.json`, in every mode. (medium, small)
6. A context inspector with per-layer provenance. (medium, small)
7. Agent presets (persona, model, mode) exportable as JSON; skip separate-home profiles. (medium, medium)

### 3.9 Permissions and safety

**How Hermes does it**

- **Gate order** in `check_all_command_guards`: container skip, then `_floor_block` (hardline blocklist, `sudo -S` stdin guard, user `approvals.deny` globs), then YOLO/off/permanent allowlist, then unattended-context policy, then the dangerous-pattern detector, then a human or guardian decision (`tools/approval.py:1079-1210`, `tools/approval_floors.py:1-60`). Floors hold even under YOLO. Message: "This command is on the unconditional blocklist and cannot be executed via the agent - not even with --yolo...".
- **Hardline list** is a short regex set anchored on command position so `git commit -m "rm -rf /"` does not trip it; commands are normalized first (`tools/approval_detection.py:97-148,520-540`). The soft-tier pattern table is large; **no pattern count is cited here** because the notes disagreed (about 50 versus about 100) and the table was not read in full.
- **Modes** `smart` (default), `manual`, `off`. In smart mode a cheap auxiliary model answers APPROVE / DENY / ESCALATE; the command is treated as untrusted input, shell comments are stripped, and the operator policy goes only in the system prompt (`tools/approval_smart.py:1-150`). The `approval` slot is `_aux(30)`.
- **Human choices** once / session / always / deny; "always" writes a `command_allowlist` that refuses compound commands (`;`, `&`, `|`, `>`, `$(`) (`tools/approval_prompt.py:20-175`).
- **Rejection reaches the model** as a tool result built from a fixed STOP clause: "The user has NOT consented to this action. Do NOT retry this command, do NOT rephrase it, and do NOT attempt the same outcome via a different command." with the user's free text appended; a separate human-facing summary; distinct outcomes denied / timeout / cancelled; "silence is not consent" (`tools/approval.py:694-775`). Circuit breaker: `denial_breaker_threshold` default 3 consecutive guardian denials (0 or negative disables it) appends a hard-stop clause (`tools/approval.py:60-124`, `hermes_cli/config_defaults.py:1672-1674`).
- **Headless contexts** (cron, `-q`, webhook) default to deny immediately instead of hanging (`hermes_cli/config_defaults.py:1645-1665`).
- **File writes:** sensitive-path hard deny, binary guard, protected instruction files always ask, stale-overwrite blocker (`tools/file_tools_write_guards.py:1-225`). The code says plainly: "Every guard here is defense-in-depth, NOT a security boundary: the terminal tool runs as the same OS user."
- **Secrets:** one pattern list (`agent/redact.py:1-110`), fail-closed egress scrub, subprocess env scrubbing (`tools/environments/local.py:265-395`).
- **Injection defences:** web/browser/MCP results wrapped in `<untrusted_tool_result source="...">` with the token defanged (`agent/tool_dispatch_helpers.py:447-480`); a shared threat-pattern library with scoped severity (`tools/threat_patterns.py:1-45`); a `plugins/security-guidance` plugin that scans written content and appends a warning (warns, does not block by default; its patterns are an Apache-2.0 fork, `plugins/security-guidance/NOTICE`).
- **SSRF:** private/loopback/link-local blocked, metadata hosts always blocked, DNS-rebinding closed with connect-time IP checks (`tools/url_safety.py:1-14`).
- **MCP trust tiers:** `trust: untrusted` requires approval for every tool without `readOnlyHint` (documented).
- **Local-by-default threat model** (`SECURITY.md`): containment is the real boundary, not the approval gate or redaction.

**EveryAI today.** `AgentMode` maps to OpenHands `NeverConfirm` (Full auto) or `AlwaysConfirm`; the app auto-responds per mode. `shell_readonly.dart` is a good classifier but there is no dangerous-command detection, no deny floor, no persisted "always allow" (`permissions.allow/deny` stored but unenforced), no redaction, and the sidecar and macOS app are unsandboxed. `web_fetch` in `chat.zig` accepts any http(s) URL with no SSRF check and no untrusted-data delimiters. Whether the sidecar inherits the user's environment was not confirmed (Dart `Process.start` defaults to inheriting).

**Hermes vs opencode.** opencode uses a last-match-wins ruleset `{permission, pattern, action: allow|ask|deny}`, an "always allow" stored as a command-prefix from an arity table, and rejection feedback passed to the model verbatim (`opencode-agents.md` item 5, 2.5). Hermes instead layers a floor, a detector and a guardian. Take opencode's ruleset shape for the enforced `permissions.allow/deny`, and Hermes's floor and denial template on top.

**Recommendations** (one merged "command policy" workstream; it replaces the separate `dangerous_shell.dart` and `command_policy.dart` proposals)

1. **Command policy**: hardline floor, enforced `deny`/`allow`, dangerous-pattern classifier with a "why flagged" text, once/session/always approvals that never match compound commands. **Caveat:** for the floor to fire in Full auto, Full auto can no longer be OpenHands `NeverConfirm`; the app would answer every action, adding a round trip per tool call and changing the replay model. Prototype and measure latency before calling this small. (high, medium)
2. **Denial template** with the user's reason verbatim and distinct outcomes (see section 1 item 3). Verify that OpenHands `respond_to_confirmation {reason}` reaches the model (our Plan refusals suggest yes). (high, small)
3. **SSRF + untrusted wrapper for `web_fetch`**: resolve host, reject loopback/RFC1918/link-local/::1/metadata, re-check each redirect hop, cap body, wrap in `<untrusted_tool_result>`, one sentence in the constant system prompt. (high, medium)
4. Protected-file writes always ask in every mode. (medium, small)
5. **Redaction** and **SSRF** as one workstream with a shared pattern list; give the sidecar a minimal explicit environment (`includeParentEnvironment: false` with PATH, HOME, locale) after confirming it does not already. (medium, medium)
6. Smart guardian: **later**. It adds a billed LLM call per flagged command and a new route, and it needs a flagged-command stream from step 1 first. (low-medium, medium)
7. Unattended-session policy and a persistent Full auto badge, persisted per session. (low, small)

### 3.10 Git, checkpoints and rollback

**How Hermes does it**

- **Shadow git store.** One bare repo at `~/.hermes/checkpoints/store/` for all projects (`GIT_DIR=store`, `GIT_WORK_TREE=<project>`), per-project ref `refs/hermes/<hash>` and private index; plumbing only (`write-tree`, `commit-tree`, `update-ref`); user's `.git` never touched; user git config ignored; trees over 50,000 files skipped; nested repos stored as gitlinks and not captured (`tools/checkpoint_manager.py:316-350,509-580,1418-1563`).
- **Opt-in.** `checkpoints.enabled: False` is the config default (`hermes_cli/config_defaults.py:486-487`; `max_snapshots: 20` at `:489`; `max_total_size_mb: 500`).
- **Triggers.** Before `write_file`/`patch` and before destructive terminal commands, once per directory per iteration (`agent/tool_executor.py:97-116,1036-1056`, `agent/turn_iteration_prep.py:379-380`). Container backends excluded.
- **Safe restore.** After each successful write the file's sha256 goes in a per-project ledger. `/rollback N` restores only files whose current hash equals the recorded hash; others land in `skipped_user_edits` ("Kept your hand-edits"). `--all` forces a full restore (`tools/checkpoint_manager.py:827-918,1143-1383`).
- **Undo the undo.** `_restore` snapshots first ("pre-rollback snapshot") (`:1269-1270`), then `undo_last` rewinds the last chat turn so the transcript matches (`hermes_cli/cli_commands_mixin.py:413-470`, `hermes_cli/cli_session_mixin.py:823-878`).
- **Worktrees.** `.worktrees/<name>` on `hermes/<name>`, based on the freshly fetched remote tip, `.worktreeinclude` copy list, hooks/fsmonitor/filters neutralized on checkout (documented, `hermes_cli/worktree_ops.py:275-376`). Dirty or unpushed trees archive to `refs/hermes/archive/<tree>` as a `git stash -u`-shaped pair of commits before removal; stale sweep every 6 h (`hermes_cli/worktree_archive.py:1-20`).
- **Hardened git env**: pins `core.fsmonitor=false`, `core.hooksPath=/dev/null`, `core.pager=cat`, BatchMode ssh (`hermes_cli/_subprocess_compat.py:287-303,436-465`).

**EveryAI today.** One worktree per session at `<App Support>/.../<slug>` on `everyai/<slug>` from the main checkout's HEAD; a throwaway-index snapshot to `refs/everyai/<slug>/turn-N` before each user send (turn >= 2); "Restore files to here" runs `git clean -fdq` then `git restore --source=<ref>` and says "The conversation stays as it is."; squash merge, push, PR, hunk revert; wrapper hooks strip AI credit lines (`frontend/lib/features/code/git/git_service_io.dart`, `code_providers.dart:394-405,631-635`).

**Hermes vs opencode.** opencode snapshots to a shadow repo too, but per model step with `track()` at step start and a stored patch part per assistant message, and supports revert plus unrevert (`opencode-agents.md` 2.6). EveryAI sits between: per user turn, real worktrees. Hermes adds the hand-edit ledger and conversation rewind.

**Recommendations**

1. **Pre-restore snapshot and stop `clean -fdq` from deleting user files.** Cheap and safe: take `refs/everyai/<slug>/pre-restore-<n>`, offer Undo. (high, small)
2. **Rewind the conversation with the files** via OpenHands `/fork` or `/navigate`. `/navigate` semantics were never tested, so effort is probably **larger than medium**; prototype against a live server first. It is still the highest-value item here, since the agent otherwise builds on edits that no longer exist. (high, large)
3. **Agent-write ledger** from the event stream so restore skips user hand-edits. (high, medium)
4. Finer checkpoints before destructive steps, deduped per iteration, using the inverse of `shell_readonly`. (medium, medium)
5. Archive-before-remove and a stale sweep; cap checkpoint refs. (medium, medium)
6. Hardened git invocation; `.worktreeinclude`; optional fresh-remote base. (medium, small)
7. Tell the agent its worktree path and branch in `workingRules`; check first whether it already does. (low, small)

### 3.11 Robustness of the agent loop

**How Hermes does it**

- **Truncation.** Order in `recover_from_truncation`: repetition-loop abort, headroom check (under 512 tokens ends the turn), thinking-exhaustion and repetition-dominated detection, then text continuation up to 4 times with a nudge: "[System: Your previous response was truncated by the output length limit. Continue exactly where you left off...]" (`agent/turn_truncation.py:407-503,178-371`). A truncated tool call is never executed; it is re-issued up to 4 times with a boosted cap, `max(32768, 2x cap)` bounded by the model's limit, then fails with plain copy "Nothing was changed" (`:373-425`, `agent/turn_failure_copy.py:313-376`).
- **Empty replies.** A ladder: reuse streamed content, reuse prior text after housekeeping tools, one post-tool nudge, thinking-prefill twice, 3 budgeted retries, fallback provider, `(empty)` sentinel (`agent/turn_empty_response.py:1-315`). A cost guard: two identical zero-output empties skip retries; an empty attempt costing over $0.25 drops the budget to 1 (`agent/empty_response_guard.py:1-48`).
- **Retries.** Jittered exponential backoff, base 5 s, cap 120 s, honoring Retry-After (`agent/retry_utils.py:121-134`); `api_max_retries` 3 (`hermes_cli/config_defaults.py:24`, `agent_init.py:1342`); a failure classifier of about 25 reasons picks rotate-credential, compress, fall back or abort (`agent/error_classifier.py:34-64`); each terminal failure has fixed copy and a retryable flag.
- **Doom loops** (`agent/tool_guardrails.py:35-110,250-300`): warn on the 2nd identical failing call, block at 5; same-tool different-args failures warn at 3, halt at 8; idempotent no-progress; repeating A,B,A,B cycles; per-turn caps (50 `web_search`, 50 subagents). Warnings are appended to the tool result; hard stops are off for interactive platforms by default. Config block `tool_loop_guardrails` (`hermes_cli/config_defaults.py:545-560`).
- **Iteration budget.** Parent default 500 (unchecked in this pass; the subagent figure is 250 per `config_defaults.py:1348`, not 50), an opt-in one-shot warning appended to a tool result, and at exhaustion one extra request with no tools asking for a final summary (`agent/iteration_budget.py:1-60`, `agent/chat_completion_helpers.py:2279-2330`).
- **Compaction.** Triggers at `compression.threshold` 0.50 of the window, floored at 0.75 for windows under 512K (`hermes_cli/config_defaults.py:564-600`). Lean tail mode (2.5% of window), one summarizer call on `auxiliary.compression`, a "REFERENCE ONLY" prefix that says tools stay active and only the latest user message is the active task, deterministic fallback summary, cooldowns 60/300/900 s (`agent/context_compressor.py:258-298,3510-4075`). The compaction eval harness measures recall vs retained tokens.
- **Tool-output caps** at three layers (3.3).

**EveryAI today.** `backend-exp/src/chat.zig` loops up to 6 steps with no `finish_reason=length` handling, no empty-reply nudge, no loop guard, no final tool-less summary when steps run out, and only a manual UI retry on upstream errors. `anthropic.zig` maps `max_tokens` to `length`. Chat has no compaction. Code relies on the OpenHands condenser and stuck detector (configuration unverified). The UI reacts to `stuck`/`error` with a banner and a Retry message.

**Hermes vs opencode.** opencode v2 fails an unfinished tool call on `length` with an explicit "not executed because the output token limit..." result and an input excerpt, continues text with a synthetic "Your last response hit the output token limit" message, gives up after two consecutive continuations, and fits `max_tokens` to the remaining context (`opencode-agents.md` item 1, 2.7). Hermes does the same with more attempts (4) and a boosted cap. Both agree on the core rule: never execute a truncated tool call. opencode's doom-loop guard is three identical consecutive calls and asks the user; Hermes appends a note and hard-stops only unattended. opencode's compaction template is Objective / Important Details / Work State / Next Move / Relevant Files; Hermes's is longer with Errors & Fixes and anchors. Either template is fine.

**Recommendations**

1. **`finish_reason=length` in `chat.zig`** (and a clear error in the gateway non-stream path). Retry the same step up to 4 times with a doubled cap bounded by the catalog output limit; continue text with a nudge up to 2-4 times. (high, small)
2. **Final tool-less summary** when the step budget runs out, plus a notice on the last tool result at step max-1. (high, small)
3. **Server-side retry with backoff and Retry-After**, only before the first SSE byte, and a per-model fallback (Anthropic route to OpenRouter route via `App.route`). Return 429 with Retry-After from the gateway so LiteLLM backs off; whether LiteLLM already retries is unverified. (high, medium)
4. **Typed error codes** in the SSE `error` event (`truncated`, `empty_response`, `context_overflow`, `rate_limited`, `content_policy`, `out_of_steps`) with localized copy and an action. (medium, small)
5. **Doom-loop guard** for chat server tools (hash tool+args+result; note at the 3rd repeat, skip at the 5th) and a controller-side detector in Code over `ActionCall`/`ToolResult`. (medium, medium)
6. **Chat compaction** with a structured summary, a REFERENCE ONLY prefix, user messages quoted verbatim, run on the cheap model; store as a message part and keep the original rows. Merges two earlier suggestions. (high, large)
7. Empty-reply nudge for cheaper/free models. (medium, small)
8. **Explicit OpenHands condenser settings**, after checking the v1.59 schema, plus a "tools stay active after condensation" line. Add an agent eval that forces a condensation. (medium, small)
9. Cap and truncate `web_fetch` output with a visible marker. (medium, small)

### 3.12 Questions, todos and plans

**How Hermes does it**

- **`clarify`** is a blocking tool: 1-5 questions, each with up to 4 choices and `multi_select`; the first choice is the recommendation and is suffixed "(Recommended)" (stripped again before the model sees it); the UI adds "Other". The answers return inside the tool result of the same turn, JSON with per-question `status` (answered/skipped/unanswered) and an `outcome` (submitted/cancelled/timed_out/undelivered) (`tools/clarify_tool.py:1-201`). Description: "one form beats a chain of clarify calls ... Prefer deciding low-stakes questions yourself". Locked answers survive a timeout and unanswered requests are redelivered after reconnect (`tools/clarify_batch.py:1-40`, `tui_gateway/server_requests.py:1-40`). Timeout: `agent.clarify_timeout` is 3600 s in `config_defaults.py`; another doc says 300 s for the TUI, **unresolved**, do not quote 300. Headless workers are told not to call clarify (`agent/prompt_builder.py:335-338`). `clarify` is in `_NEVER_PARALLEL_TOOLS`.
- **`todo_list`**: one revisioned in-memory list; items `{id, content, status pending|in_progress|completed|cancelled, parent}`; caps 4000 chars and 256 items; replay from the newest paired tool result; after compression only active items are re-injected as a synthetic user message. Rules include only ONE in_progress and "Mark an item completed only after the work is verified done" (`tools/todo_tool.py:1-285`).
- **`/plan`** is a prompt, the plan is a file; approval is conversational (no approve button, no exit tool) (`agent/plan_prompt.py:1-71`).
- **`/goal`** loop with a judge; judge failures are fail-open (`hermes_cli/goals.py:1-35`).

**EveryAI today.** `ask_user_question` (1-4 questions, option label + description, multi-select) and `present_plan` client tools; answers return as the next user message because OpenHands acks client tools immediately. No status/outcome protocol, no recommended-option convention, no plan file.

**Hermes vs opencode.** opencode's `question` tool also blocks and returns "User has answered your questions: ..." as the tool result, shares the "(Recommended)" first-option convention, and `plan_exit` switches agent and queues "The plan at X has been approved" (`opencode-agents.md` item 3, 2.8). Both keep the turn alive; EveryAI's client tools end the turn, which is a sidecar constraint. Hermes's status/outcome envelope is the part worth taking.

**Recommendations**

1. **Answer envelope** with per-question status and an outcome so skip, dismiss and timeout are distinguishable. (high, small)
2. **Question guidance**: batch independent questions; recommended option first with a badge stripped on return; no options in prose; decide low-stakes things yourself. (high, small)
3. Persist approved plans as `.everyai/plans/*.md` (merged with 3.5 item 6) and adopt the plan-craft block (exact paths, verify commands, risks). (high, medium)
4. Todo semantics: revisions, one in-progress, nesting, cancelled state; Chat todo tool later. (medium, medium)
5. Cancel signal on open cards when the agent moves on or an interrupt happens. (medium, small)
6. `/goal` later (merged into 3.6 item 6). (medium, large)

---

## 4. Cross-cutting areas the topic notes missed (verified in the clone)

| Area | What exists | Takeaway for EveryAI |
|---|---|---|
| Model routing | Credential pool with `fill_first`, `round_robin`, `random`, `least_used`, per-model cooldowns (`agent/credential_pool.py:118-126`); `fallback_providers` chain; auxiliary router with 402 fall-through (`agent/auxiliary_client.py:1-10`) | Our gateway is the single choke point; per-model fallback and cooldowns belong in `openrouter.zig`/`anthropic.zig` (3.11 item 3) |
| Cheap-model slots | `auxiliary.*` keys: compression, skills_hub, approval, review, mcp, title_generation, memory_query_rewrite, tts_audio_tags, voice_chat, triage_specifier, kanban_decomposer, profile_describer, goal_judge, curator, monitor, background_review (`hermes_cli/config_defaults.py:750-800`) | Consolidate into one routing table in `agents.zig` so every side task (follow-ups, compaction, review, guardian, voice, title) picks a model by slot name, billed to the session |
| Cost and usage | `usage_pricing`, `billing_usage`, `account_usage`, `insights`, `rate_limit_tracker` | Not read; our `usage_events` already covers per-call cost. Background tasks need a slot and a visible line in the meter |
| Parallel tool execution | Ordered parallel/sequential segments, 8 workers, never-parallel set (`agent/tool_executor.py:135`, `agent/tool_dispatch_helpers.py:30-36`) | The chat loop in `chat.zig` runs tools serially; parallel read-only tools (`web_fetch`) could cut latency |
| Deferred tools | `tool_search` bridge with live evals (`evals/tool_search/`) | Relevant if Chat tool schemas grow; not now |
| Plugin system | `plugins/plugin_loader.py`, hooks such as `pre_approval_request`, `context_engine`, `security-guidance` | EveryAI needs an extension story before skills/plugins make sense; none exists |
| MCP | `mcp_servers` in config, include/exclude filters, trust tiers (documented) | Not read beyond that |
| ACP | `acp_adapter/` and `hermes-acp` entry point | Relevant as a standard way to embed an external harness; not read |
| Evals | `evals/` (compaction recall, prompt_footprint, tool_search, provider_fallback, token_accounting) | The strongest process takeaway; see roadmap item P-3 |
| Security as one workstream | Floors, `agent/redact.py`, `tools/threat_patterns.py`, `tools/url_safety.py`, `SECURITY.md` | Treat redaction, SSRF, injection wrapping and the command floor as one security workstream with a written threat model |

---

## 5. Where Hermes' design does not transfer (failure modes of copying)

Hermes is one Python process. Several designs lean on in-process state that EveryAI's three-part loop (Flutter app, Zig gateway, OpenHands sidecar) does not have:

- **ContextVars for write provenance and the frozen YOLO flag** assume one process owning the tools. EveryAI cannot enforce read-before-write inside OpenHands tool calls; enforce only on edits our own app performs.
- **Forked review agent on the same cached prefix.** The prefix belongs to the sidecar's conversation. A review through the gateway is a separate request with its own cache write cost.
- **Rewriting tool results** (spill-to-file, redaction) is impossible from the client for sidecar-run tools.
- **Mid-run steer injection** needs agent-server support.
- **Blocking tool results for questions**: OpenHands acks client tools at once, so answers must come back as a user message.
- **Docs-only claims** (voice barge-in multipliers, checkpoint pruning, worktree sweep tiers, platform feature lists) are documentation-level. Do not treat them as verified behavior.

---

## 6. Proposed EveryAI roadmap items

Duplicates are merged (the earlier notes double-counted effort). "In OpenHands" means works around the sidecar without changing it; "Our layer" means Flutter or Zig code we own; "Needs sidecar" depends on an OpenHands capability that is unverified.

### 6.1 Chat

| ID | Item | Impact | Effort | Layer |
|----|------|--------|--------|-------|
| C-1 | Truncation recovery, final summary on step exhaustion, typed error codes, empty-reply nudge (3.11 items 1,2,4,7) | high | small | Our layer (`chat.zig`) |
| C-2 | SSRF + untrusted wrapper + output cap for `web_fetch` (3.9 item 3, 3.11 item 9) | high | medium | Our layer (`chat.zig`, `tools.zig`) |
| C-3 | Memory store, `memory` UI tool, Settings > Memory (3.5 item 1) | high | medium | Our layer |
| C-4 | `session_search` UI tool over local FTS5 (3.5 item 2) | high | small | Our layer |
| C-5 | Custom instructions and personality, appended after the cached prefix (3.8 item 4); date/surface tier (3.7 item 5) | high | small | Our layer |
| C-6 | Question card envelope and guidance, for a future chat-side ask tool (3.12) | medium | small | Our layer |
| C-7 | Dictation + read-aloud + voice-turn note (3.4 items 1-3) | high | medium | Our layer (new `audio.zig`, new `features/voice/`) |
| C-8 | Chat compaction with a structured summary (3.11 item 6) | high | large | Our layer |
| C-9 | Server retry/backoff/fallback in the upstream client (3.11 item 3) | high | medium | Our layer (also helps Code via gateway) |

### 6.2 Code

| ID | Item | Impact | Effort | Layer |
|----|------|--------|--------|-------|
| K-1 | Command policy: floor, enforced allow/deny, classifier, once/session/always (3.9 item 1) | high | medium, prototype Full-auto change first | Our layer (Flutter `domain/`); Full auto semantics change how we use OpenHands confirmation |
| K-2 | Denial template with user reason and outcome types (3.9 item 2) | high | small | Our layer; relies on OpenHands passing `reason` (likely) |
| K-3 | Pre-restore snapshot, no destructive `clean`, ledger of agent writes (3.10 items 1,3) | high | small + medium | Our layer |
| K-4 | Conversation rewind via `/fork`/`/navigate` (3.10 item 2) | high | large | Needs sidecar behaviour (untested) |
| K-5 | Pinned workspace snapshot, finishing-the-job block, generalized context notes (3.7 items 1,4,6) | high | small | Our layer |
| K-6 | Question envelope + guidance; plan file in `.everyai/plans/` (3.12 items 1-3) | high | small to medium | Our layer |
| K-7 | Project memory file and user memory via suffix (3.5 item 3) | high | medium | Our layer |
| K-8 | Skills: verify OpenHands native loading, then library, validator, `/learn` (3.1 items 1,2,6) | high | medium | Depends on the check |
| K-9 | Background process client tool + Processes/Terminal panes (3.3 item 3) | high | large | Our layer |
| K-10 | Preview tools for the agent (3.3 item 4) | high | large | Our layer |
| K-11 | `delegate` subagents, child mode derivation, cheap worker tier, live cards, child worktrees (3.6 items 1-5) | high | large (one workstream) | Our layer on top of plain OpenHands conversations |
| K-12 | Doom-loop detector over `ActionCall`/`ToolResult` (3.11 item 5) | medium | medium | Our layer |
| K-13 | Steer marker + prompt note; true mid-run injection (3.7 item 2) | high | small / unknown | Marker: our layer. Injection: Needs sidecar |
| K-14 | Nested AGENTS.md hints as user-message notes (3.8 item 3) | medium | medium | Our layer, only if OpenHands lacks it |
| K-15 | Explicit condenser settings and an eval that forces condensation (3.11 item 8) | medium | small | Needs a schema check |
| K-16 | Post-session skill/memory review, staged for approval (3.1 item 3) | high | large | Our layer + gateway; blocked on consent/cost decision |

### 6.3 Platform and backend

| ID | Item | Impact | Effort | Layer |
|----|------|--------|--------|-------|
| P-1 | One `auxiliary`-style slot table in `agents.zig` for all side tasks | medium | small | Our layer |
| P-2 | Gateway: 429 + Retry-After, truncation errors (not partial tool calls), typed errors | high | medium | Our layer |
| P-3 | Eval gate for prompt and tool-description changes; add a compaction recall eval and truncation scenarios to `tool/agent_eval` | medium | small | Process |
| P-4 | Redaction library + shared secret patterns (3.9 item 5) | medium | medium | Our layer |
| P-5 | Scheduled agent runs / notifications | high | large | Needs a design decision (no sync with local-only chat) |
| P-6 | Messaging bridge, pairing | medium | large | Defer; conflicts with local-only history; ask the user |

### 6.4 Drop (does not fit the current product shape)

- Profile distributions and multiplexed gateway profiles
- Remote config plane and managed scope
- Modal, Daytona and other cloud terminal backends
- Kanban
- Honcho and other external memory providers
- Wake word and GPT-Live voice mode
- Cross-platform session-key function (no multi-platform ingress today)

---

## 7. License notes

- Hermes is **MIT**, Copyright (c) 2025 Nous Research. Code and prompt text may be copied verbatim provided the copyright and permission notice ship with the copied portions. Add a Hermes entry next to the OpenHands and opencode notices.
- **Safe to port with attribution (appear original to Hermes):** the denial STOP clause, the truncation continuation nudge, the compaction template and REFERENCE ONLY prefix, the todo and clarify descriptions, the review do-not-capture lists, the spoken-script normalizer rules. Re-read `LICENSE` and per-file headers before copying large blocks.
- **Check provenance before copying verbatim:** `OPENAI_MODEL_EXECUTION_GUIDANCE` and similar family blocks resemble community and vendor prompts, and `GOOGLE_MODEL_OPERATIONAL_GUIDANCE` is documented as "adapted from OpenCode's gemini.txt" (`agent/prompt_builder.py`). Paraphrase the ideas.
- **Third-party notices inside Hermes:** `plugins/security-guidance/patterns.py` is an Apache-2.0 fork (see `plugins/security-guidance/NOTICE` and `LICENSE`). Regex lists such as the hardline set should be re-derived and tested by us, not pasted.
- **Product rules from the project notes still apply:** no AI identifiers in commits or PRs, and no agent-visible mention of Hermes or any model name in commit guidance.
- Not legal advice. If we ship verbatim text, keep a provenance list in the notices file.

---

## 8. Unverified claims and open questions

**Not verified against source (carry these as hypotheses)**

1. OpenHands 1.59 behavior: whether it natively loads AgentSkills/microagents (`.agents/skills`), AGENTS.md/CLAUDE.md, applies a condenser and stuck detector by default, truncates terminal observations, accepts a message mid-run without interrupting, or shows `respond_to_confirmation {reason}` to the model. Several "high impact" recommendations may duplicate the sidecar. Check these first.
2. `/navigate` and `/fork` semantics for conversation rewind.
3. Whether LiteLLM inside OpenHands already retries 429/5xx against our gateway.
4. Whether the sidecar inherits the user's environment (Dart default is to inherit).
5. Whether EveryAI's `workingRules` already tells the agent its worktree path and branch.
6. Subagent iteration default is 250 (`config_defaults.py:1348`); the parent default of 500 was not re-checked.
7. Pattern counts in the dangerous-command table: not cited because the notes disagreed and the table was not read in full.
8. Clarify timeouts per surface (3600 s default in config vs 300 s mentioned for the TUI): unresolved.
9. `checkpoints.enabled: False` is confirmed at `config_defaults.py:487`; effectiveness and pruning behavior are documentation-level.
10. Skill nudge wiring: the counter and default 10 are confirmed at `agent_init.py:1288`; how it combines with the memory nudge into one review prompt was inferred from the prompt selection table in `agent/background_review.py`.

**Documentation-level only (docs, `plugin.yaml`, or comments; not traced in adapter source)**

- Platform count (about 27) and per-platform feature lists (Telegram, Discord, Slack).
- Voice barge-in multipliers and thresholds, wake-word details, $0.05/min for gpt-live (from a code comment).
- Checkpoint pruning tiers, worktree sweep tiers and timers, delegation background-completion behavior, MCP trust tiers, profile distributions.
- The Claude Code column in the memory table: general knowledge, not source.

**Not read**

- `gateway/run.py` end to end, adapter internals, `hermes-official-plugins` contents, `agent/usage_pricing.py` and billing modules, MCP config, `acp_adapter/`, the compaction eval results, `tools/browser_url_policy.py`, `tools/browser_vault_tool.py`, the Kanban dispatcher, and the full `DANGEROUS_PATTERNS` table.

**Decisions needed from the user before building**

1. **Consent and cost of background work.** The self-improvement review costs real tokens (about 30K per event per a code comment) and the user pays cost x1.15 for work they did not request. Need an opt-in, a visible meter line, and a hard per-session budget before any background review ships.
2. **Local-only history vs anything server-side**: scheduled runs, a messaging bridge, and Chat memory snapshots all need a storage answer.
3. **Full auto semantics**: moving from `NeverConfirm` to app-answered confirmations so the floor can fire.
4. **Agent extension story**: skills, agents and plugins need a stable format (agentskills.io `SKILL.md` is the cheapest to be compatible with).
5. Per project rules: ask before tackling any new Anole gap; none of the above requires one.
