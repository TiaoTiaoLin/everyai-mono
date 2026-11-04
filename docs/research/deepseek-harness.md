# DeepSeek Harness (dsh): what it does and what EveryAI should take

Date: 2026-10-30. Scope: not only the coding build, but also chat, tool usage, document formats, SVG/diagrams/charts, images, video and design. Companion docs: `docs/research/hermes-agent.md`, `docs/research/opencode-agents.md`.

Citation format: `path:lines` relative to the dsh clone root (`/private/tmp/claude-501/deepseek-research/deepseek-harness`) unless a URL is given. Nothing was run; every claim is from docs and READMEs unless marked otherwise. EveryAI-side claims come from the research notes plus CLAUDE.md, and were not re-read in the EveryAI source for this document.

## 1. Sources

### Official (github.com/deepseek-ai)

| Repo | License | Commit | What it is |
|------|---------|--------|-----------|
| `deepseek-harness` | MIT, "Copyright (c) 2026 DeepSeek" | `ce7073d51254c26cd63b22a60835b8f948deb447` (2026-10-30) | `dsh`: TypeScript monorepo on the Cordis plugin framework. Web UI (`npx @deepseek-ai/dsh web`, port 3080), Electron app, headless runner, TS and Python SDK (JSON-RPC), ACP server. "Developer preview", breaking changes expected. |
| `dsh-libreoffice-kit` | MPL-2.0 | `b19bb73c74ed893b8a5d1716d32df32a113ed31b` | Office to PDF and PNG, spreadsheet recalculation CLI, prebuilt LibreOffice engines. Used by the Office skills and the previewer. |
| `dsh-node-addon-require-builtin` | MIT | `a58d359...` | HMR plumbing. Not relevant. |
| `deepseek-recipe` | not checked | `935817c...` | Rust/Python prompt rendering and token encoding. Not a harness. |
| `awesome-deepseek-agent` | none declared | `9546b8f...` | A list of third-party integration guides. |

Docs: https://deepseek-harness.github.io/deepseek-harness/ (same as `docs/` in the repo), API docs https://api-docs.deepseek.com/ (guides: `thinking_mode`, `tool_calls`, `kv_cache`, `vision`, `json_mode`, `files_api`). Models seen: `deepseek-flash` (text and image input) and `deepseek-v4-pro` (text only). Janus (multimodal generation research) is a separate model repo and is not wired into dsh.

### Community (not read)

Hermes (see `hermes-agent.md`), opencode (see `opencode-agents.md`), and DeepSeek-TUI, Reasonix, Pi, Crush, Cline, Kilo Code, Qwen Code, Cherry Studio, LobeHub and others listed in `awesome-deepseek-agent`. Not cloned. The consumer app chat.deepseek.com has no public source, so nothing is known about it.

## 2. Executive summary: top 10 ideas for EveryAI

| # | Idea | Impact | Effort | Layer |
|---|------|--------|--------|-------|
| 1 | **Pass reasoning back in the chat tool loop.** The DeepSeek API returns a 400 if `reasoning_content` of earlier turns is omitted while tools are present (https://api-docs.deepseek.com/guides/thinking_mode). `chat.zig` streams reasoning to the app but does not put it back into the assistant history entry, per the topic notes (unverified here, and OpenRouter forwarding is untested). | high | small | `chat.zig`, `openrouter.zig` |
| 2 | **Context compaction plus tool-result pruning for Chat and Code.** Prune old tool results first (no model call), then summarize the oldest span using the same system prompt and tools so the cache prefix is reused; keep originals, record a shadow range. Hermes and opencode recommend the same (C-8 in hermes-agent.md). | high | medium to large | `chat.zig`, Flutter chat builder |
| 3 | **Render-then-look loop for visual artifacts** (SVG, HTML, slides, charts): rasterize the result and return it to the model as an image tool result, capped at 1 to 2 passes. dsh does this for Office files via LibreOffice (`packages/skill/skill-office/assets/office-render/SKILL.md`). | high | medium | `chat.zig`, artifact renderers |
| 4 | **Validate tool arguments and return typed errors** so the model can self-correct. dsh normalizes every denial, throw or bad result to an `isError` result (`docs/tool-execution-pipeline.md`). EveryAI marks failure by the output starting with "Error". | high | medium | `chat.zig` `runTool` |
| 5 | **Harden artifact HTML and SVG.** Parser-based SVG allowlist instead of the regex sanitizer; HTML artifacts in an `allow-scripts` iframe without same-origin plus a CSP, and a static/interactive toggle (dsh: `packages/client/ui-sidebar-documentpreview/README.md:51,62,64`). Bundle Mermaid offline. | high | small to medium | `svg_view.dart`, `web_view.dart` |
| 6 | **DOCX and PDF export for document artifacts, PPTX speaker notes.** dsh needs a LibreOffice engine; EveryAI can write minimal OOXML client-side next to `pptx_writer.dart`. | high | medium | `artifacts/export/` |
| 7 | **`present_files` client tool for Code sessions** (dsh `present`, `docs/tool-catalog.md:741`): the agent declares final files, the app shows deliverable cards that open in the planned Preview pane, bytes never enter model context. | high | medium | `features/code/` |
| 8 | **Image normalization and offload.** Resize to the vision grid at attach time, label each image with id and dimensions, replace the oldest images with stable placeholders in stepped quanta (`packages/llm/llm-deepseek/README.md:95,101`). Also make generated images model-visible for edits. | medium to high | medium | attachments, `chat.zig`, `images.zig` |
| 9 | **Mode-change notice deduped against what the model last saw, and a stable tool set across toggles** (`docs/subsystems/plan.md`). EveryAI already has `modeNote` and `present_plan`; this closes a lost-note failure. Opencode has the same re-assert idea. | medium | small | `code_providers.dart`, `transcript.dart` |
| 10 | **Reasoning effort tiers (off/low/high/max) and cache-hit accounting.** Parse `prompt_cache_hit_tokens` and `prompt_cache_miss_tokens` into `cached_tokens` for DeepSeek models; a per-chat effort control. Overlaps with the `/v1/agents` effort work. | medium | small | `openrouter.zig`, composer |

Not recommended: dsh's default session-log upload to DeepSeek (privacy), the Cordis "everything is a plugin" architecture (EveryAI uses OpenHands as the loop), a LibreOffice sidecar for now, video generation (nobody has it; needs the user's go-ahead as a new gap).

## 3. Architecture

- **Plugin tree.** dsh is a Cordis plugin tree composed at boot from profiles (`web`, `headless`, `sdk`, `sdk-minimal`, `acp`) and bundles, with YAML patch layers. `dsh-base` is the shared first layer (model adapters, tools, persistence, sandbox, approval, settings, credentials). Core services: `ctx.sessions`, `ctx.systemPrompt`, `ctx.tools`, `ctx.agents`, `ctx.agentLoop`, `ctx.llm`. (`docs/architecture.md`)
- **Three event classes.** Session events are durable (append-only log). `agent/*` events are live and transient. Capability events (`fs/*`, `tools/*`, `telemetry/*`) carry policy. SDK users wanting replay should consume `session/event`. (`docs/agent-lifecycle.md`)
- **Step loop.** Inbox of follow-up messages, claimed per step, authoritative `agent/pre-step` waterfall, then request, stream, tools. A request error goes through `agent/request-error`, which can retry in the same step. (`docs/agent-lifecycle.md`)
- **Tool pipeline.** Log `tool/call`, then pre-execute (hooks, permission, sandbox), approval, monotonic guards, execute, post-execute, finalize, `tools/result`. Exceptions become `isError` results. (`docs/tool-execution-pipeline.md`)
- **About 30 tool packages.** bash and PTY, read/edit/write/apply_patch/read_image, glob and grep, web_search and web_fetch, todo, plan mode, subagent and agent teams, jobs, goal, schedule, lsp, MCP resources, browser use (Stagehand), computer use, `run_code` (programmatic tool calling), `skill`, `present`, `ask_user_question`, `propose_action`. Generated schemas: `docs/tool-catalog.md`.
- **Client.** React plugins (`packages/client/ui-*`) fill UI slots; the right sidebar previews files. A Creator mode lets the agent author plugins and pages.
- **Extension path.** Community plugins through a marketplace (topic `dsh-plugin`), `docs/cookbook/adding-a-tool.md`.

## 4. Coding agent harness

### How DeepSeek does it

1. **Append-only session log, request derived from it.** Compaction writes a `user/message` with `surfaceOp: replace` over a range and keeps originals. Resume, fork and replay are lossless. (`docs/agent-lifecycle.md`, `docs/subsystems/compaction.md`)
2. **Steering and queueing in the loop.** Messages enter an inbox, claimed per step. EveryAI does queue-while-busy and Option-Enter steer in the app layer.
3. **Guarded tool pipeline** with approval as a stage; unanswerable approval means deny. Plan mode is "soft guidance": sandbox mode and approval policy enforce restrictions independently (`docs/subsystems/plan.md:5`).
4. **Plan mode.** A prompt section while active, a silent plugin-sourced notice appended once when the last request header described the other state, and an `exit_plan_mode` tool (`docs/tool-catalog.md:670`) kept registered after first admission so toggles do not break the tool-schema cache. "Keep planning" is a failed call carrying feedback. (`docs/subsystems/plan.md`)
5. **Compaction.** Pressure check in `agent/pre-step`, plus reaction to confirmed overflow errors. Order: prune tool results, then summarize the oldest balanced span, keeping a priced recent tail. The summary call replays the system prompt, tools and shadowed messages byte for byte so the provider's warm prefix is reused (`packages/compaction/compaction-basic/README.md:116,245`). It is bracketed by `compaction/start`, `summary`, `end` events (`docs/subsystems/compaction.md`).
6. **DeepSeek driving.** Effort `off|low|high|max` (`packages/llm/llm-deepseek/README.md:45,59,85,103`), sent as `output_config.effort` on the Anthropic-style endpoint. Prior reasoning is passed back verbatim whether or not the turn called a tool (`README.md:173`). Models declaring in-history system updates get changed system prompts appended after cached history instead of rewriting the first message.
7. **Out-of-band wire extensions.** `x-deepseek-harness-user-id`, `-session-id`, `-compact` headers and `dsh_*` body fields stay outside `messages`, so they never alter the cached prefix (`docs/deepseek-llm-api-wire-extensions.md:27-28`). The session-log upload can include cwd, prompts, content and tool results.
8. **Sub-agents** behind one seam (in-process spawn/fork, ACP, Claude Code, Codex, nested SDK). Child gets one self-contained task, no parent conversation, shares only the working directory; depth tracked in the session header.
9. **`run_code`** (programmatic tool calling) and on-demand **skills** reduce round trips and prompt size (`docs/tool-catalog.md:622`; schema not read).

### EveryAI today

The OpenHands 1.59.0 sidecar is the loop. Modes live in `agent_mode.dart` (Ask, Auto-edit, Plan, Full auto). Read-only auto-approval is in `shell_readonly.dart`. `modeNote` is sent on the first message and after each switch. `present_plan` and `ask_user_question` exist. The `task` subagent tool is removed because it breaks conversation create. No compaction or pruning; the context ring is a meter only. `Condensation*` events are decoded as UnknownEvent. Caching is solid (constant prompt and tools, breakpoints, 58 to 94 percent hits).

### Recommendations

| Item | Impact | Effort | Notes |
|------|--------|--------|-------|
| Surface OpenHands condenser events, add manual compact | medium | small | First check whether conversation create accepts a condenser (unverified). |
| Diff `Transcript.notedMode` against the mode at every send so a lost note cannot leave a stale mode | medium | small | dsh dedups against the last request header. |
| Verify mode toggles do not change the client tool JSON | medium | small | `client_tools` are fixed at create, probably already stable. |
| Own `delegate` client tool (fresh-context second conversation, depth cap) | medium | large | Same as hermes C-/opencode items; do once. |
| Skills on demand for Code (router plus per-format) | low to medium | medium | Check OpenHands native skills first. |
| `purpose` tag on auxiliary calls and `usage_events` | low | small | compact, title, followups, image. |

## 5. Chat and tool usage

### How DeepSeek does it

- **Thinking mode with tools needs `reasoning_content` passback.** Quote: "Pass back the reasoning_content from all previous turns... Omitting it returns a 400 error." (https://api-docs.deepseek.com/guides/thinking_mode). Within one turn each tool sub-request carries reasoning produced so far.
- **Strict function calling (beta)**: `/beta` base URL, `strict:true`; all properties `required`, `additionalProperties:false`; `minItems/maxItems` unsupported (https://api-docs.deepseek.com/guides/tool_calls).
- **Disk KV cache**: automatic, prefix-based, usage reports `prompt_cache_hit_tokens` and `prompt_cache_miss_tokens` (https://api-docs.deepseek.com/guides/kv_cache).
- **Typed streaming blocks**: text, reasoning and tool-call blocks with indexes; `block-end` carries the assembled block (`docs/subsystems/llm-streaming.md`).
- **Tool cards**: per-tool view slots, a pending row as soon as the call is named, generic "Tool call · name" fallback, visible failures (`packages/client/ui-tool/README.md`).
- **`ask_user_question`** blocks by default with an optional timed mode (`docs/tool-catalog.md:548`).

### EveryAI today

`chat.zig` loops up to a step cap (hermes-agent.md says 6), streams reasoning to the app, appends assistant text plus raw tool calls (so reasoning is dropped on replay, per the topic notes). Tool schemas are non-strict and use `minItems/maxItems`. Failure detection is by the "Error" string prefix. Cache accounting reads `cached_tokens` only.

### Recommendations

| Item | Impact | Effort |
|------|--------|--------|
| Reasoning passback in the loop and in replayed history (persist reasoning parts); Fake test asserting the second request carries it | high | small |
| Argument validation, typed failure flag, capped repair retries | high | medium |
| Strict-compatible second tool JSON for `deepseek/` slugs | medium | medium |
| Parse DeepSeek cache fields; per-chat effort control | medium | small |
| Running/failed tool rows with Retry; generic row for unknown tools | low | small |
| Truncation recovery (`finish_reason=length`) and step-exhaustion summary | high | small (from hermes and opencode docs) |

## 6. Building documents and formats

### How DeepSeek does it

There is no artifact tool. The model writes real files in the workspace and declares them.

- **Office skills on demand**: a router plus six skills (docx, pptx, xlsx, render, recalculate, export-pdf). Only short catalog entries are in the prompt; the model calls `skill` to load full instructions, so the cached prefix is untouched (`packages/skill/skill-office/README.md:12`, `assets/office/SKILL.md`).
- **`present`**: at most 4 files per call, validates regular files in the session filesystem, records paths only, host shows cards after the turn ends. Limitation: no versioning (`packages/deliverables/tool-present/README.md`).
- **Render-then-inspect**: render pages to PNG with the LibreOffice kit into a private temp dir, look, delete. Content-only edits are verified by reopening with python-docx or python-pptx, no render. A blank render counts as renderer failure: "Content and structure checks passed; visual inspection was not completed." (`assets/office-render/SKILL.md`)
- **In-place edit** is open-edit-save on the real file in a script, then reopen to verify. Formulas need a separate recalc step because openpyxl writes no cached values.
- **Right-sidebar previewer**: renderers markdown, code, PDF (PDF.js), image/SVG, spreadsheet (no charts), HTML; DOCX and PPTX through local PDF conversion with an LRU cache; auto-reload on change. "Preview, not editing" (`packages/client/ui-sidebar-documentpreview/README.md:144`).
- **Single engine**: `dsh-libreoffice-kit` for convert, render, recalculate. Output can differ from native Office.

### EveryAI today

The model emits structured payloads (`create_artifact`, `update_artifact`, `edit_artifact` with exact find-and-replace, make_slides, quiz, flashcards, chart, svg, diagram), rendered inline or in a panel with versions. Exports: md, code, html, svg, mmd, json, tsv, and PPTX through a hand-written OOXML writer. Gaps: no DOCX, XLSX or PDF export, no PPTX speaker notes, no image or chart in PPTX, no user editing of artifacts, no `present` for Code, Artifacts sidebar page is a stub. EveryAI is ahead on live editing (`edit_artifact`) and interactivity; dsh is ahead on real Office fidelity.

### Recommendations

| Item | Impact | Effort |
|------|--------|--------|
| DOCX and PDF export (minimal OOXML plus the `pdf` package) | high | medium |
| PPTX speaker notes (notesMaster) and figures | high | medium |
| `present_files` client tool and Preview pane for Code | high | medium |
| Table artifact kind with CSV and XLSX export | medium | medium |
| User editing of document artifacts as a new version, fed back through `Artifacts.seed` | medium | medium |
| Office skills text for Code sessions (python-docx and friends), loaded on demand | medium | medium |
| Fill the Artifacts sidebar page | low | small |

## 7. SVG, drawings, diagrams and charts

### How DeepSeek does it

No first-party SVG, Mermaid, diagram or chart tool exists. In `docs/` and the packages I looked at, the string "mermaid" appears only as a dev dependency of the docs site (`package.json:278`, `THIRD_PARTY_NOTICES.md:267`), not as a product feature. Math renders through KaTeX (`packages/client/ui-primitives/src/markdown/katex.tsx`). What exists:

- **SVG as an inert image.** Rendered through a Blob URL in `<img>`, so scripts cannot run or reach the app DOM; fit width, pan, pinch zoom, drag-out (`packages/client/ui-sidebar-documentpreview/README.md:64`).
- **Two HTML preview modes.** Static: DOMPurify-sanitized document in an iframe with no sandbox permissions, CSP blocking scripts, external resources, connections and forms. Interactive (when Coding Tools is on): Blob iframe with exactly `sandbox="allow-scripts"`, no `allow-same-origin`, relative `.js`/`.css` inlined under limits (4 MiB per asset, 32 MiB total, 64 assets), and a failed read fails the whole preview (`README.md:51,62`). This is the de facto chart route (inference, not observed).
- **Render-to-image self-check** exists only for Office files.

### EveryAI today

Strong: `render_svg`, `render_diagram`, `render_chart` (fl_chart), slides, quiz, flashcards. Weak spots reported in the topic notes: regex SVG sanitizer, Mermaid loaded from jsDelivr (breaks offline), no sandbox or CSP found in `web_view.dart` by grep, no PNG export, and the model never sees what it drew.

### Recommendations

| Item | Impact | Effort |
|------|--------|--------|
| Parser-based SVG allowlist (drop `on*`, style `url()`, non-fragment hrefs) | high | small |
| Sandboxed iframe plus CSP for HTML artifacts; static mode toggle | high | medium |
| Bundle Mermaid as an asset | high | small |
| PNG export for svg, diagram and chart; reuse in PPTX | high | medium |
| Client-reported parse error returned to the model for one repair pass | medium | medium |
| Preview pane in Code reusing the renderers | medium | medium |
| One line in the constant system prompt choosing chart vs svg vs html | low | small |

## 8. Images, video and design

### How DeepSeek does it

Strong image input, no generation, no video, no design tool.

- **Durable attachments**: PNG, JPEG, WebP, GIF validated and normalized to 8-bit sRGB before the message is accepted; one refused image fails the whole message; events store digest, format and dimensions only. Audio and video have no dedicated handling (`packages/attachment/attachment/README.md`).
- **Route-sized request images** on the vision grid: 14px patches, 3:1 downsampling, up to 1024 tokens per image, so a 16:9 image goes as 1708x961; `imagePixelBudget` integer or `low`; 85/75/60 JPEG/WebP quality ladder; each image is preceded by text with its id and dimensions; text-only routes get placeholders (`packages/llm/llm-deepseek/README.md:49,95`).
- **Offload and pricing**: `maxImagesPerRequest` 600, `maxRequestFilesBytes` 128 MiB; the oldest images become placeholders in stepped quanta so the cached prefix is not rewritten each turn; images are priced before sending (`README.md:66,101,177`).
- **`read_image`** tool, refused unless the exact routed model declares image input (`docs/tool-catalog.md:1131`).
- **Browser and computer use** feed screenshots back as ordinary image blocks, the only official visual-verification path for front-ends (README only, internals not read).
- **Generation and video are explicitly "undecided"**: "Both directions are undecided." (`packages/attachment/attachment/README.md:134-136`). Anything else must be a community plugin.

### EveryAI today

`generate_image` plus `/v1/images`, attachments with per-model acceptance, Code uploads as OpenHands ImageContent. No resize or normalize step, no dimension labels, no image offload, generated images are not returned to the model, no video or design layer.

### Recommendations

| Item | Impact | Effort |
|------|--------|--------|
| Client-side image normalize and size guard (and in the gateway for Code) | high | medium |
| Make `generate_image` model-visible; add image-to-image and an image artifact kind | high | medium |
| Image offload with stable placeholders; image count in the ring | medium | medium |
| Conditional design guidance block appended after the constant prefix, brand tokens | medium | small |
| Preview screenshot attached to the next Code message | medium | large |
| Video: defer; needs async jobs and metering and the user's go-ahead as a new gap | low | large |

## 9. Comparison: DeepSeek vs Hermes vs opencode vs EveryAI

Cells for Hermes and opencode come from the two companion docs. A dash means that doc has no data on it (the images, SVG and video grep of both returned nothing), which is not the same as the tool lacking it.

| Area | DeepSeek dsh | Hermes | opencode | EveryAI today |
|------|--------------|--------|----------|---------------|
| Loop | Cordis plugin tree, event-sourced | `run_agent.py` AIAgent loop | session runner (v1/v2) | OpenHands sidecar (Code); `chat.zig` loop (Chat) |
| Plan mode | Soft prompt plus `exit_plan_mode`, tool set stable, notice deduped | `/plan` one-turn prompt, instruction only | Plan agent, reminder re-asserted after compaction, "no longer in Plan" notice | Enforced in app, `present_plan`, `modeNote` |
| Compaction | Prune then summarize, warm-prefix reuse, logged, image offload | Structured summary template, threshold 0.50, cheap model | Anchored structured summary, auto-continue nudge | None (condenser events ignored) |
| Truncation recovery | Not examined | Yes (`finish_reason=length`) | Yes, fail call with explanation | None |
| Sub-agents | Pluggable providers, fresh context | `delegate_task`, optional worktree per child | `task` tool, depth 1, resumable | Disabled (OpenHands bug) |
| Reasoning | Effort tiers, verbatim passback | not covered in the notes | not covered | Adaptive thinking for Anthropic; no passback for others |
| Skills | On demand via `skill` tool, Office set | `SKILL.md` index, progressive load | not covered | None |
| Questions | Blocking `ask_user_question`, timed mode | clarify tool | question tool | Paged question card |
| Documents | Files plus `present`, LibreOffice render and preview | not covered | not covered | Artifact tools, PPTX export, no DOCX/XLSX/PDF |
| SVG, diagrams, charts | None first-party; sandboxed HTML | not covered | not covered | Dedicated tools and renderers |
| Image input | Normalize, vision-grid sizing, offload | not covered | not covered | Attach with per-model acceptance, no resize |
| Image output, video | None ("undecided") | not covered | not covered | `generate_image`; no video |
| Safety | Pipeline, sandbox and approval independent of plan | Hardline floor, denial template, SSRF | Rule-based permissions | Mode classifier; `web_fetch` SSRF hole noted by Hermes pass |
| Evals | Not examined | `evals/` gate | not covered | `tool/agent_eval` |
| Privacy | Uploads session log by default | Local | Local | Local history |

## 10. Roadmap items

Ids are new (D-prefix). Where Hermes or opencode proposed the same, the existing id is noted so it is built once.

### Chat

| ID | Item | Impact | Effort |
|----|------|--------|--------|
| D-C1 | Reasoning passback in tool loop and replay; persist reasoning parts | high | small |
| D-C2 | Tool argument validation, typed failure, repair retries (cap 2) | high | medium |
| D-C3 | Compaction and tool-result pruning (same as hermes C-8) | high | large |
| D-C4 | Render-then-look verification for svg, html, slides | high | medium |
| D-C5 | Parser-based SVG sanitizer; sandboxed HTML iframe plus CSP; bundled Mermaid | high | small to medium |
| D-C6 | DOCX and PDF export; PPTX notes and figures; PNG export | high | medium |
| D-C7 | Image normalize and offload; model-visible generated images; image artifact kind | high | medium |
| D-C8 | Conditional design guidance block after the constant prefix | medium | small |
| D-C9 | Tool rows: pending, failed with Retry, generic fallback | low | small |
| D-C10 | Table artifact with CSV and XLSX | medium | medium |
| D-C11 | User editing of document artifacts as versions | medium | medium |

### Code

| ID | Item | Impact | Effort |
|----|------|--------|--------|
| D-K1 | `present_files` client tool, deliverable cards, Preview pane | high | medium |
| D-K2 | Decode `Condensation*`, show notice, manual compact (check condenser at create) | medium | small |
| D-K3 | Mode note diffed against last-seen mode; verify tool JSON stable across toggles | medium | small |
| D-K4 | Preview screenshot into next message | medium | large |
| D-K5 | Office skill text on demand (check OpenHands skills first) | medium | medium |
| D-K6 | `delegate` client tool (merge with Hermes and opencode subagent items) | medium | large |

### Backend

| ID | Item | Impact | Effort |
|----|------|--------|--------|
| D-B1 | Parse `prompt_cache_hit_tokens` and `prompt_cache_miss_tokens`; effort param | medium | small |
| D-B2 | Strict-compatible tool JSON for `deepseek/` slugs | medium | medium |
| D-B3 | `purpose` column on `usage_events` and header on gateway calls | low | small |
| D-B4 | Image size guard in gateway and chat | medium | small |
| D-B5 | `finish_reason=length` handling (hermes C-1) | high | small |

## 11. Spot-check log

Checked against the clone before writing (commit `ce7073d`):

- Plan soft guidance: `docs/subsystems/plan.md:5` confirmed ("Plan mode is **soft guidance**...").
- Warm prefix: the claim is in `packages/compaction/compaction-basic/README.md:116,245`, not `docs/subsystems/compaction.md:19-23` as the first notes said; fixed. The compaction lock text at `compaction.md:19` is accurate.
- Effort tiers and `output_config.effort`: `packages/llm/llm-deepseek/README.md:45,59,85,103` confirmed. Line 57, cited in the notes, is the `baseURL` row; fixed.
- Reasoning passback sentence: confirmed at `README.md:173` (the notes cited 173-181 for the whole block).
- Preview behavior: `ui-sidebar-documentpreview/README.md:51,62` (HTML modes), `:64` (SVG as `<img>`), `:144` ("Preview, not editing") confirmed.
- Image future/undecided: `packages/attachment/attachment/README.md:134-136` confirmed verbatim.
- Office skill catalog (router plus six): `skill-office/README.md:12` confirmed; skill directories listed on disk.
- Tool-catalog headings: `ask_user_question` 548, `run_code` 622, `exit_plan_mode` 670, `present` 741, `read_image` 1131 confirmed (the notes cited 668-670, 743, 23 and 33 loosely).
- Wire headers: `docs/deepseek-llm-api-wire-extensions.md:27-28` confirmed.
- Correction to the scout: "no `mermaid` string in the source" is wrong as stated. It appears in `package.json:122,138,278` and `THIRD_PARTY_NOTICES.md:267`, as a docs-site tooling dependency. I found no mermaid renderer or tool in the product, but did not grep package source files (the glob failed).

## 12. Unverified

- Nothing was run. `dsh` behavior is as documented. TypeScript source (agent loop, plan mode, compaction implementation, browser-use) was not read, except filenames.
- `run_code` and `skill` schemas (`tool-catalog.md:622, 1735`), the dsh default system prompt, the full approval policy names, and in-process sub-agent behavior were not read.
- `office-docx` and `office-xlsx` SKILL.md bodies were not read; only router, render and pptx.
- Whether OpenRouter forwards `reasoning_content` or `reasoning` for `deepseek/*`, and whether the 400 occurs through OpenRouter, is untested.
- EveryAI claims (reasoning dropped in `chat.zig:271`, no sandbox or CSP in `web_view.dart`, string-prefix failure detection, step cap, whether `generate_image` output is shown to the model) come from the scout's grep and CLAUDE.md, not from a fresh read.
- Whether OpenHands 1.59.0 accepts a condenser at conversation create, or has native skills, is unchecked.
- Licenses: `deepseek-recipe` unchecked; copying dsh skill text needs a THIRD_PARTY_NOTICES review (the repo itself is MIT).
- No community harness (Hermes aside, via its own doc) was read; chat.deepseek.com has no public source; Janus not inspected.
- Hermes and opencode docs have no images, SVG or video data, so those table cells are blank rather than "no".
