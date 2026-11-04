# Hermes second pass: chat, tooling and visual output

Source: Hermes agent clone at commit `903230b1` (`/private/tmp/claude-501/hermes-research/hermes-agent`). Paths below are relative to that repo unless they start with `backend-exp/` or `frontend/` (EveryAI). The first pass is `docs/research/hermes-agent.md`.

## Spot-check log (done before writing)

Verified against the clone:
- `gateway/platforms/base.py:3202-3212`: `extract_media` masks code/quotes/JSON values, dedupes on expanded path, handles `[[audio_as_voice]]` and `[[as_document]]`. Correct.
- `tools/web_tools_truncate.py`: `DEFAULT_EXTRACT_CHAR_LIMIT = 15000`, 75% head / 25% tail, line-snapped. Correct.
- `tools/video_generation_tool.py:1-10`: no in-tree provider, "Video edit/extend are deliberately not exposed". Correct.
- `tools/image_generation_catalog.py`: `upscale` False everywhere, unsupported keys stripped. Correct.
- `plugins/video_gen/openrouter/__init__.py:156-157`: poll interval 10 s, deadline 900 s. Correct.
- `tools/preview_tool.py:5`: "~576 -> ~210 schema tokens". Correct (so "about 366 saved" in the other note is consistent).
- `tools/vision_tools_history_budget.py`: 256 KB embed target, "158 times in 15 minutes". Correct.
- `skills/creative/claude-design/SKILL.md`: seven surface archetypes (l.168-190), ten slop tells (l.436-460), graded Verification (l.592+). Correct. Verification is advisory text only.
- `optional-skills/creative/concept-diagrams/SKILL.md:243-245`: width >= chars x 8 + 48 (14px), x 6.5 + 48 (12px), viewBox height = bottom + 40. Correct.
- `agent/prompt_builder.py:705-708`: api_server hint ("assume plain text", base64 inline up to 5MB). Correct.

Fixes to claims in the topic notes:
- EveryAI `"Shown to the user."` is at `backend-exp/src/chat.zig:420` (not 413-414); the generate_image fixed string is at `chat.zig:497`. `max_tool_steps = 6` is at `backend-exp/src/config.zig:40` (correct).
- The Office skill has 20 files in `scripts/`, of which `docx_common.py` is a shared helper, so 19 runnable scripts. Correct as stated by note 1.
- `web_fetch` scheme check is at `chat.zig:439` and the only validation there is the http/https prefix; no private-address check found in that file. Whether the Anole client adds one is unverified.
- The note's "10 tells" table is right, but the "scored diagnostic" is text the model writes, not code. Same for "verify": no code forces a screenshot.

## Summary: top ideas for EveryAI chat (ranked)

| # | Idea | Impact | Effort |
|---|------|--------|--------|
| 1 | Render feedback to the model: server-side SVG/Mermaid validation and real error strings instead of "Shown to the user." | high | small |
| 2 | Design + SVG authoring brief in the system prompt (surface archetype, slop self-check, SVG checklist), plus a tool-use enforcement line | high | small |
| 3 | Recover from truncated tool calls and exhausted step budget (`finish_reason=length`, tool-less final step) | high | small |
| 4 | Harden `web_fetch` (SSRF, redirects, head+tail window, paging) and add model-callable `web_search`; source ledger feeding `sources` events | high | medium |
| 5 | Inline HTML widgets with theme variables and a send-back hook | high | medium |
| 6 | `generate_image` edit/reference support with capability-gated schema and stable image ids | high | medium |
| 7 | Server-side docx/xlsx/csv delivery and in-place edit of uploaded Office files | high | large |
| 8 | Render-and-look loop (client rasterizes visual, returns image tool result, budgeted) | high | large |
| 9 | Chat `ask_user` clarify card (reuse Code question card) | medium | medium |
| 10 | Richer tool-step display (`label`, `preview`, `progress`, grouping) | medium | small |
| 11 | Video: attachment analysis first, `generate_video` second (ask the user first per project rules) | medium | large |
| 12 | Editable sketch surface (Excalidraw-like JSON) | medium | large |
| 13 | Spill oversized tool results with `read_result` paging | low | medium |

Do not copy: Hermes's skill sprawl and plugin catalog. Keep a few constant prompt blocks plus at most one on-demand guide tool.

## Topic 1: chat, tooling and deliverables

### Hermes mechanisms

1. **MEDIA: tag delivery contract.** The model writes `MEDIA:/abs/path`; `BasePlatformAdapter.extract_media` scans a masked copy, dedupes, strips tags from visible text, honours `[[audio_as_voice]]` / `[[as_document]]`. Adapters pick send method by extension. `send_message` reuses the extraction and reports "Delivery incomplete" on a dropped attachment. Cites: `gateway/platforms/base.py:3202-3272`, `tools/send_message_tool.py:236-293, 457-464, 676-716`.
2. **Per-surface hints.** The system prompt tells the model what each renderer can do (CLI: Markdown not rendered; API server: assume plain text, inline images up to 5MB; Telegram: no tables). Cites: `agent/prompt_builder.py:667-733`, `agent/system_prompt.py:430-460`, `plugins/platforms/telegram/adapter_hint.py:5-14`.
3. **`::preview` inline widgets (desktop).** Model writes HTML and `::preview{file="x.html"}` on its own line; renderer uses a sandboxed iframe (`allow-scripts`, no same-origin), injects theme CSS vars, auto-sizes via postMessage, and widget clicks send a hidden user turn (`window.hermes.send`). Cites: `apps/desktop/src/components/assistant-ui/inline-preview-directive.tsx:1-40`, `agent/prompt_builder.py:689-700`.
4. **Desktop UI tools.** `desktop_preview` (open/close/read, one tool with an action enum), `annotate_preview`, `set_theme`, and `clarify` (1-N questions in one call, recommended first, auto "Other"). Cites: `tools/preview_tool.py:1-60`, `tools/annotate_preview_tool.py`, `tools/set_theme_tool.py`, `tools/clarify_tool.py:136-175`.
5. **Office docs as skill + scripts.** No docx/pptx/xlsx tool: a `microsoft-office` skill points to 19 scripts (`pptx_create/edit/from_template/render/read`, `docx_*`, `xlsx_*`). `pptx_edit` merges identically formatted runs before replace, swaps images in place, edits chart series. Skill says to render the deck and check each PNG with `vision_analyze`. Cites: `skills/productivity/microsoft-office/SKILL.md:108,156-157`, `references/powerpoint.md:85-175`.
6. **Grounded citations ledger.** `sources.py` owns url to `[n]`; model only emits integers it was handed; `verify` exits non-zero on unknown ids. Cites: `skills/research/grounded-citations/SKILL.md:1-150`. (Script itself unread.)
7. **Web tools.** `web_search` returns metadata only; `web_extract` takes up to 5 URLs, 15000-char budget, head+tail window with a footer pointing to the stored full text and a `read_file` call. Cites: `tools/web_tools.py:515-557`, `tools/web_tools_truncate.py:1-95`, `tools/tool_result_storage.py:1-8`.
8. **Capability-gated image/video tools.** Optional args advertised only when the active model honours them; handler still accepts them for replay. Cites: `tools/image_generation_tool.py:604-640, 925-1054`, `tools/video_generation_tool.py:1-10, 274-364`.
9. **Diagrams as skills.** `excalidraw` (elements JSON in `.excalidraw` envelope), `architecture-diagram` (HTML + inline SVG), each naming sibling skills for out-of-scope subjects. Cites: `optional-skills/creative/excalidraw/SKILL.md:1-50`, `skills/creative/architecture-diagram/SKILL.md:1-40`.
10. **Design skill.** `claude-design`: workflow, anti-slop rules (l.418), scored diagnostic (l.436), graded verification (l.592), short final reply, "Never say done if the file was not written." Routes to `popular-web-designs` and `design-md`.
11. **Tool-use enforcement and steering.** Injected block for models that narrate rather than act ("Never end your turn with a promise of future action"); a trusted mid-turn steering marker. Cites: `agent/prompt_builder.py:261, 344-354, 597-611`, `agent/system_prompt.py:300-322`.
12. **Tool-step display as per-platform setting** (tiers HIGH/MEDIUM/LOW, `tool_progress`, grouping, `cleanup_progress`, `live_status`). Cites: `gateway/display_config.py:1-50`, `gateway/run_turn_progress.py:34-60`, `tools/tool_labels.py:44-163`. Mostly irrelevant to a single-surface app except the label/preview idea.

### EveryAI today

Strengths: interactive renderers (quiz, flashcards, chart, slides + PPTX, mermaid, sanitized SVG), artifact panel with versions and checked `edit_artifact`, PDF/Word export, byte-stable cacheable prompt (`backend-exp/src/tools.zig`).

Gaps: one terse bullet per tool in `tools.zig:23-40`; `web_fetch` (`chat.zig:~439`) checks only the scheme, keeps 20k chars, one URL, no PDF; no model-callable `web_search`; no source ledger; `max_tool_steps = 6` with no recovery; no docx/xlsx/csv; no video; `generate_image` is prompt + aspect_ratio only; `tool_status` carries only `detail`.

### Recommendations

See the fix list below; items 1-4, 6-7, 9-10, 13 of the ranked table come from this topic.

## Topic 2: SVG, drawing, images, video and design

### Hermes mechanisms

1. **Capability-rebuilt `image_generate` schema**, fail-closed capabilities. `tools/image_generation_tool.py:604-637, 876-929, 997-1054`.
2. **FAL catalog with payload whitelists**; upscale off by default because it degraded text/CJK/faces; OpenRouter plugin lists models by `output_modalities` containing image. `tools/image_generation_catalog.py:1-60`, `plugins/image_gen/openrouter/__init__.py:1-62, 262-270`.
3. **Sandbox path mapping** for generated images (`agent_visible_image`). `tools/image_generation_tool.py:287-362`.
4. **`video_generate`**: plugin-only, schema from model catalog; OpenRouter plugin `POST /api/v1/videos`, poll 10 s, deadline 900 s, clamp duration/resolution/aspect. `plugins/video_gen/openrouter/__init__.py:74-141, 156-157, 256-270`.
5. **`vision_analyze`**: image enters the main model's context as a multimodal tool result; optional crop `region`; 256 KB embed target; per-image repeat cap. `tools/vision_tools.py:594-755`, `tools/vision_tools_history_budget.py:1-30`.
6. **`video_analyze`** via a video-capable aux model (about 50 MB). `tools/vision_tools.py:1056-1192`.
7. **Preview pane tools**: `desktop_preview`, `drive_preview` (click/type/scroll by element ref), `annotate_preview`. `tools/preview_tool.py`, `tools/drive_preview_tool.py:100-152`.
8. **SVG/diagram skills with checklists.** concept-diagrams 12-point validation (label-width formula, viewBox = bottom + 40, no gradients/shadows, arrows not crossing boxes). `optional-skills/creative/concept-diagrams/SKILL.md:225-262`.
9. **Design skill**: surface-first composition (seven archetypes), ten-tell slop audit, diagnose then repair. `skills/creative/claude-design/SKILL.md:165-200, 436-460`.
10. **Design skill family**: `claude-design`, `popular-web-designs` (54 systems), `design-md`.

### EveryAI today

Blind tool results (`chat.zig:420`, `chat.zig:497`). Client-side regex SVG sanitizer only (`frontend/lib/features/artifacts/ui/renderers/svg_view.dart:8-13`). Mermaid from jsDelivr CDN (`web_view.dart:29`), so offline fails with no feedback. No image input for generation, no vision-in-the-loop, no video, no drawing surface, no design doctrine, single static tool list (cache-friendly but advertises image tools to models that cannot use them).

## Concrete fix list for EveryAI

Ordered by value per effort. Project rule: ask the user before starting any new Anole gap; video needs a go-ahead.

1. **Validate and report in `runTool`** (`backend-exp/src/chat.zig` `.ui` branch near l.413-420). For `render_svg`/`create_artifact(kind=svg)`: strict XML well-formedness, viewBox present, size cap; return "SVG not well-formed at line N; call render_svg again" instead of "Shown to the user." and do not emit the `tool` event on failure. Mermaid: a lightweight header/bracket check. Reuse the existing `edit_artifact` miss-message pattern.
2. **System prompt additions** (`backend-exp/src/tools.zig` `system_prompt`, keep byte-stable, under about 600 tokens): (a) SVG checklist (viewBox, label width at ~8 px/char at 14px plus 48 padding, height = bottom + 40, no gradients/shadows, label every shape, use currentColor or both-theme-safe palette); (b) HTML/slides design block (name the surface in one line, ten slop tells to avoid, use brand tokens, ask one or two questions for new high-fidelity work); (c) enforcement lines: "If you say you will draw or build something, call the tool in the same response" and "Never paste SVG/Mermaid source as plain text when a render tool exists". Optional later: `load_guide(name)` server tool for the long design text.
3. **Tool-loop recovery** (`chat.zig` loop ~236-280, `buildBody`): if `finish_reason == length` with tool_calls, retry with larger `max_tokens` or instruct split into create + `edit_artifact`; on the final step send one more request with tools disabled. `max_tool_steps` stays in `config.zig:40`.
4. **`web_fetch` hardening** (`chat.zig` webFetch ~439-440): block loopback, link-local (169.254.x), RFC1918, and metadata hosts after DNS resolution and on every redirect; byte cap; head+tail window with "N of M chars shown" footer and `start`/`char_limit` args; up to 5 URLs; PDF URLs. Add `web_search(query, limit)` returning metadata only (OpenRouter/Exa path) and a per-turn source ledger (url to n) that emits incremental `sources` events (extend `frontend/lib/features/chat/data/chat_transport.dart` handling only if the event shape changes).
5. **Inline HTML widget** (`frontend/lib/features/artifacts/ui/renderers/web_view.dart`, `visual_view.dart` `InlineVisual`): `inline: true` for `kind=html`, theme-variable prelude from `lib/core/theme/everyai_brand.dart` (--foreground, --accent, --card, --border, app font, transparent background), height reporting, JS channel `everyai.send(prompt)` that submits a hidden user turn answered by `edit_artifact`. Keep the `sandbox` without same-origin equivalent (no navigation, no network except explicit allow).
6. **Images**: extend `generate_image` in `tools.zig` and `chat.zig` generateImage (~493), `backend-exp/src/images.zig` with `source_image` / `reference_ids[]` (attachment or earlier image ids), advertised only when the selected model's `input_modalities` allow; ship a small fixed number of tool-set variants (with/without edit) so caching holds. Return a stable image id in the tool result. Add a long-edge cap and JPEG ~256 KB for history copies of images (`frontend/lib/features/attachments/`) before any vision-in-the-loop.
7. **Documents**: new UI tools `make_document` and `make_spreadsheet` (typed schemas in `tools.zig`, new `VisualKind` in `frontend/lib/features/artifacts/domain/artifact.dart`, writers beside `export/pptx_writer.dart`); `edit_file(file_id, ops)` for uploaded Office files modelled on `pptx_edit` ops. Offline Mermaid asset in app bundle and a real XML allowlist in `svg_view.dart` `sanitizeSvg`.
8. **Render-and-look**: `check_render(id)` client step using `svg_raster.dart` / `RepaintBoundary.toImage`, JPEG downscale, one look per artifact, vision-capable models only. Needs a client-supplied tool-result round trip in `chat_transport.dart`/`chat_providers.dart` and an image-bearing tool result in `chat.zig`.
9. **Chat clarify card**: `ask_user` UI tool; move `frontend/lib/features/code/ui/transcript/question_card.dart` into a shared widget; prompt rule to use it only when the answer changes output materially (style, format, length for design, drawing, video).
10. **Tool-step display**: add `label`, `preview`, optional `progress` to `tool_status` (`chat.zig`), group consecutive steps in `frontend/lib/features/chat/ui/message_view.dart`, show failure text, and a skeleton while a large SVG/slides call streams.
11. **Video** (ask first): accept video attachments for models with video input modality (reuse attachment picker greying), then a `generate_video` server tool polling OpenRouter `/api/v1/videos` with `tool_status` progress, nearest-value clamping, result as blob with an inline player card; schema from catalog `output_modalities` in `models.zig`.
12. **Drawing**: `kind=sketch` for `create_artifact` (rect/ellipse/arrow/text/line elements, id-addressable for `edit_artifact`), CustomPainter with pan/zoom/drag, export SVG/PNG. Pairs with item 8.
13. **Spill**: store oversize tool results per session and add `read_result(id, start, count)`.
14. **Code sessions**: add a media/HTML delivery rule to `workingRules` (`frontend/lib/features/code/domain/agent_mode.dart`): write images/HTML under the project and refer to them by path; the future Preview pane offers Open on new image/HTML paths.

## Unverified claims

- Hermes `scripts/sources.py`, `pptx_edit.py`, `pptx_render.py` and docx/xlsx scripts were not opened; behaviour is from SKILL.md/references.
- Renderer side of `::preview` (iframe sandbox, theme injection, sizing) comes from a code comment and prompt text; `apps/desktop` was only grepped. Also `prompt_builder.py` notes a webui hint was removed because no such renderer exists.
- No code in Hermes was found that forces screenshot verification; it is skill guidance.
- `video_analyze` aux call, fal/xai video plugins, and image providers other than OpenRouter and the FAL catalog were not read.
- Messaging adapters beyond the Telegram hint and base class dispatch (per-platform media limits) were not read.
- The middle of `claude-design` (typography, colour, deck rules) was read only at headings.
- Hermes output quality, and whether models follow these skills reliably, was not tested.
- EveryAI side: Flutter renderers not read in depth and the app not run. "No SSRF guard" rests on `chat.zig` showing only a scheme check and a grep for private addresses; the Anole client layer might block some.
- OpenRouter `/api/v1/videos` and image-input behaviour were not called live.
- Token-saving figures (576 to 210) come from a docstring, not a measurement.
