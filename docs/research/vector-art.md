# Claude-grade vector art for EveryAI

Research note, 2026-10-30. Scope: how to get Claude-quality SVG/vector art out of EveryAI, what to reuse, and how to measure it. Connectors get a short appendix because the same research pass covered them.

Legend: [V] verified by reading a file or clone in this pass; [S] from a search snippet or another doc, not re-verified; [I] my inference or proposal.

## 1. Sources

Local clones (shallow, in `/private/tmp/claude-501/connectors-vector-research/`, may be deleted):

| Source | Used for | Spot-check |
|---|---|---|
| `Chat2SVG/prompts.yaml` (system L1, expand_text_prompt L18, write_svg_code L65, svg_refine L126) | Prompt structure, refine rubric | Section headers and 512x512 viewBox confirmed [V] |
| `Chat2SVG/1_template_generation/main.py:20,104` | Refine loop: `--refine_iter` default 2 | Confirmed [V] |
| `Chat2SVG/README.md:14` | Anthropic API support since 2025-04-02 | Confirmed [V] |
| `resvg/Cargo.toml:13` | `license = "Apache-2.0 OR MIT"` | Confirmed [V] |
| `vtracer/Cargo.toml:25` | `MIT OR Apache-2.0` | Confirmed [V]. The scout listed only MIT from the LICENSE file; the manifest says dual. |
| `svgo/LICENSE`, `vtracer/LICENSE`, `SVGDreamer/LICENSE`, `VectorFusion-pytorch/LICENSE` | Licenses | First lines read: MIT-style grants [V] (full text not read) |
| `OmniSVG/README.md:231-232` | Code Apache-2.0, MMSVG dataset CC BY-NC-SA 4.0 | Confirmed [V] |
| `starvector/` | Apache-2.0 per scout listing | Not re-read [S] |

EveryAI files read: `backend-exp/src/tools.zig` (lines 20, 30-50: `render_svg`, `edit_artifact`, `generate_image`), `frontend/lib/features/artifacts/export/svg_raster.dart` (client rasterizer, 480pt cap, 2.5x scale on white), `docs/research/media/README.md` and `generation-providers.md` (Recraft vector slugs, OpenRouter `/api/v1/images`).

Papers (search snippets only, none opened): arXiv 2603.16189 (CTRL-S), 2603.29852 (VectorGym), 2509.05208 (SGP-GenBench), Chat2SVG 2411.16602.

Correction found while spot-checking: `docs/research/media/README.md` (renderer row) lists resvg as MPL-2.0. The clone says Apache-2.0 OR MIT. Fix that doc; it removes a copyleft worry about linking resvg into the backend.

## 2. Executive summary: what gets us to Claude-quality vector art, ranked

1. Design brief in the prompt (small effort, high gain). Plan first (scene, palette of 3-5 hex colors, layers with coordinates), then draw with a fixed viewBox, semantic `<g id>` layers, gradients and clipPaths, and a checklist of known failures. Chat2SVG's three tasks (expand, write, correct oddities) are the proven shape [V].
2. Server-side render check with resvg (medium, high). Today nothing on the server renders the SVG, so the model never sees failures [V]. Parse errors go back as a tool result and the model repairs in the same loop.
3. One capped render-then-look critique round (medium, high). Rasterize, show the PNG to a vision model with a defect-listing rubric, revise, re-validate. Chat2SVG defaults to 2 rounds [V]; its measured gains were on older models, so we must measure ours [I].
4. Recraft vector via OpenRouter for illustration (small, high). Returns real SVG paths, covers what LLM-written SVG draws poorly (mascots, posters, rich fills) [S: prior research].
5. Style presets and stable-id editing (small). Presets are prompt fragments appended after the cached prefix; edits go through the existing `edit_artifact` find-and-replace on stable ids.
6. Eval set before tuning (medium). Without it the critique loop cannot justify its cost.
7. Defer: StarVector, OmniSVG, SVGDreamer, VectorFusion, svgo (GPU or Node dependency, no advantage over frontier LLM plus loop).

Positioning: LLM-written SVG for diagrams, icons, logos, figures; Recraft for illustration; vtracer as a free flat-art vectorizer.

## 3. State of the art

### Model families
- Frontier chat LLMs writing SVG code (what Claude does in artifacts). Strongest at open-ended prompts, editing, text and geometry. Weak on spatial consistency (overlaps, z-order, detached parts), organic shapes, and anything needing visual feedback they never get [I, consistent with the Chat2SVG refine rubric, L126-148 [V]].
- Pipeline systems: Chat2SVG = LLM template, then SDXL/ControlNet detail enhancement, then DeepSVG-VAE shape optimization (stages 2-3 need GPU) [V from directory layout and README; code not read].
- Optimization-based: VectorFusion, SVGDreamer. Per-image diffusion-guided path optimization; minutes per image on a GPU, output often path soup. MIT [V]. Not interactive.
- Trained SVG models: StarVector, OmniSVG (4B/8B weights on Hugging Face). Apache-2.0 code [V for OmniSVG]; dataset is non-commercial [V]. GPU hosting required.
- Hosted native-vector image models: Recraft V4/V4.1 vector slugs on OpenRouter via `POST /api/v1/images` with `output_format:"svg"`, direct price $0.05-0.30 per image [S: `generation-providers.md:34,84-93`].

### Benchmarks and research (unverified; search snippets only)
- SGP-GenBench: gate on "does it render", then object, scene and compositional fidelity [S].
- VectorGym: Sketch2SVG, editing, Text2SVG, captioning; RL-trained Qwen3-VL 8B [S].
- CTRL-S: chain-of-thought SVG with GRPO; DINO and image-text similarity rewards; SVG-Sophia 145K [S].
- Also named: IntroSVG (generator-critic with rendering feedback), SVGenius, UniSVG, WildSVG, TikZilla [S].
- Common thread: render success plus visual feedback drives quality. That supports render-then-look.

### Why LLMs fail at SVG (from the Chat2SVG refine prompt, L126-148 [V], plus experience [I])
- Detached limbs, shapes hidden behind same-color shapes, wrong z-order (later elements overlap earlier ones), bad proportions, white on white, unrecognizable subject.
- Invalid XML, unescaped characters, bad path syntax, missing xmlns/viewBox.
- Text overflow and font assumptions (fonts differ between resvg, flutter_svg and browsers).
- Too many long hand-written path strings: errors compound and edits are hard.
- No feedback: failures are visible in the render, not in the code.

## 4. Techniques and reusable tools

| Tool / technique | What it gives us | License | Fit |
|---|---|---|---|
| Chat2SVG stage 1 prompts and refine loop | Plan-then-draw structure, defect-listing refine rubric, 2 refine rounds | No LICENSE file in clone [V]. Reference only; write our own wording | Use the idea |
| resvg (Rust; `crates/c-api` has `resvg.h`) | Strict parse, validate, rasterize to PNG; also high-res PNG export | Apache-2.0 OR MIT [V] | Core. CLI first, C API from Zig later. Must load fonts explicitly [S: not tested] |
| vtracer (Rust) | Raster to color SVG; free fallback to Recraft Vectorize ($0.01) | MIT OR Apache-2.0 [V] | Optional; flat art only |
| svgo (Node) | Minify, normalize, strip metadata/scripts | MIT [V] | Defer: needs a Node worker. resvg re-serialization plus the existing `sanitizeSvg` cover safety |
| Recraft vector via OpenRouter | Real SVG paths | Hosted; resale terms not stated [S] | Primary for illustration |
| StarVector / OmniSVG | Image/text to SVG, self-hosted | Apache-2.0 code; MMSVG data CC BY-NC-SA 4.0 [V] | Defer (GPU) |
| SVGDreamer / VectorFusion-pytorch | Diffusion-guided path optimization | MIT [V] | Skip (slow, GPU) |
| Excalidraw | Drawing canvas | MIT [S] | Diagrams only, not vector-art editing |
| Icon sets (Lucide, Tabler, Iconify), potrace, scour | Not examined | Unknown | Future look |

## 5. The EveryAI design

### 5.1 What exists today [V]
- `render_svg(title, svg)` inline art; `create_artifact`/`update_artifact`/`edit_artifact` (exact find-and-replace) with kind `svg`; system prompt only says "self-contained SVG, viewBox set, no scripts or external references" (`tools.zig:33`).
- App: `sanitizeSvg`, flutter_svg view, `rasterizeSvg` (client-side PNG for PDF/DOCX/PPTX export, capped at 480pt wide).
- `generate_image` is raster-only; `/v1/images` uses the chat-completions image path and cannot return SVG.
- Missing: server validation, any critique loop, design brief, style presets, element-level editing.

### 5.2 Tool schemas (proposed)

Keep tool JSON cache-stable: add these as constants appended after existing tools, in fixed order.

```json
{"type":"function","function":{"name":"generate_vector","description":"Create vector art as SVG. Use for logos, icons, posters, scenes, mascots, stickers, patterns. It plans, draws, checks the render and revises. Returns an svg artifact. Prefer render_svg for small inline explanatory figures.","parameters":{"type":"object","properties":{"title":{"type":"string"},"brief":{"type":"string","description":"What to draw: subject, mood, use, constraints."},"style":{"type":"string","enum":["flat","line_icon","isometric","geometric_logo","hand_drawn","poster","custom"]},"palette":{"type":"array","items":{"type":"string","pattern":"^#[0-9a-fA-F]{6}$"},"maxItems":6},"aspect_ratio":{"type":"string","enum":["1:1","4:3","3:4","16:9","9:16"]},"quality":{"type":"string","enum":["fast","balanced","best"]},"engine":{"type":"string","enum":["llm","recraft"],"description":"llm = hand-written SVG (diagrams, icons, logos with text). recraft = native vector model for rich illustration."},"artifact_id":{"type":"string","description":"Existing artifact to revise instead of creating."}},"required":["title","brief"]}}}
```

```json
{"type":"function","function":{"name":"check_svg","description":"Server-side render check. Returns ok, parse errors, warnings, and a PNG preview the model can look at. Called automatically by generate_vector; call directly after edit_artifact on an svg.","parameters":{"type":"object","properties":{"artifact_id":{"type":"string"},"svg":{"type":"string"},"width":{"type":"integer","minimum":128,"maximum":1024}},"required":[]}}}
```

Result shape of `check_svg` (internal): `{ok:bool, errors:[string], warnings:[string], width, height, png_base64}`. A failure is returned as the tool result so the model repairs in the same loop. Cap parse-repair retries at 2.

`generate_vector` runs as a server tool in `chat.zig`, emitting `tool_status {name:"generate_vector", status:"running", detail:"Planning" | "Drawing" | "Checking the drawing" | "Revising"}` and finally the same `tool` event the app already renders for `create_artifact` (kind `svg`). Usage events get `kind: "svg_draft" | "svg_critique"` so the meter and ledger show them.

### 5.3 Design-brief prompt (ready to paste; original wording, inspired by the Chat2SVG structure)

Append as a section loaded only when a vector request is detected or `generate_vector` is called, so the cached prefix stays constant.

```text
You are a vector illustrator. You produce SVG that looks designed, not generated.

Work in this order, and write the plan out briefly before the code:
1. Interpret. In 3-5 sentences, decide the subject, mood, point of view and the one thing the viewer should recognize first.
2. Plan. List the canvas, a palette of 3-5 hex colors (one dominant, one accent, one dark, one light; check contrast), and the layers back to front. For each layer give its main shapes with approximate coordinates and sizes.
3. Draw. Output one self-contained SVG:
   - xmlns set; viewBox "0 0 W H" matching the requested aspect (default 0 0 512 512, or 0 0 1024 1024 for detailed work); no width/height in px.
   - Document order is paint order: later elements cover earlier ones. Draw background, large shapes, mid-ground, details, highlights.
   - Group each layer as <g id="semantic-name"> (sky, hills, body, wing-left, eyes). Give key shapes meaningful ids so later edits can target them.
   - Prefer primitives (rect, circle, ellipse, line, polygon) and short paths. Use gradients and clipPaths from <defs> for depth; keep stops to the palette family. Use a consistent stroke width and corner radius.
   - No scripts, external images, external fonts, foreignObject, or event attributes. Avoid <text> unless the request needs it; if used, use a generic font stack and keep it well inside the canvas.
   - Keep it compact: no editor metadata, no unused defs, coordinates rounded to at most 1 decimal.
4. Check. Before finishing, verify: every part is attached to its body; nothing important is hidden behind a same-color shape; no white on white; proportions are believable; the subject is recognizable at 64 px.

When a rendered image of your SVG is shown to you, list every visual problem you can see (detached parts, hidden shapes, wrong layering, poor proportions, low contrast, clutter, cropped content), then fix the SVG. Fix the picture's faults; do not bend the picture to excuse the code. Keep existing ids so edits stay targetable. Return the complete corrected SVG.
```

Style presets (each ~60-100 tokens, appended after the brief): flat (no outlines, 4 colors, bold shapes), line_icon (24 or 48 grid, 2 px round strokes, no fills except accent), isometric (30 degree axes, three face shades per solid), geometric_logo (grid construction, 2 colors, works in one color), hand_drawn (slightly irregular strokes, round caps, paper-warm palette), poster (strong focal shape, large type-free composition, grain via light gradient).

### 5.4 The render-then-look loop

Sequence (engine = llm):

1. Draft. Model call D1 with brief + preset + design prompt; returns plan and SVG.
2. Validate. `check_svg` (resvg). On error: tool-result with the message, model fixes (max 2 repair calls).
3. Look. Rasterize to ~768 px PNG on white. Call C with image + SVG + the critique rubric. Output: defect list and a revised SVG.
4. Validate the revision. If it fails or is worse on the checks (render error, byte size > 2x), keep the previous SVG.
5. Repeat step 3 once more only for quality = best.
6. Finalize: `sanitizeSvg` in the app; optional svgo later. Emit the artifact.

Engine = recraft: call `/api/v1/images` with a vector slug and `output_format:"svg"`, run `check_svg`, optionally one critique round for a color or composition change request using `edit_artifact`.

Quality tiers (draft model, critique rounds, critique model):

| Tier | Draft | Critique | Use |
|---|---|---|---|
| fast | Haiku 5.5 | 0 | icons, simple shapes |
| balanced (default) | Sonnet 5.5 | 1, Haiku 5.5 or Gemini flash class vision model | most requests |
| best | Opus 5.5 | 2, Sonnet 5.5 | posters, complex scenes |

Budgets and caps: max 1 draft + 2 repair + 2 critique calls per request; `max_tokens` ceiling per call; a per-request `charged_micros` budget; wallet preflight (402 before start, same as chat) using the worst-case estimate; stop and return the best valid SVG when a cap hits. Record every call in `usage_events`.

Cost per image (formula, not measured):

```
cost = (1.15) * sum over calls of (input_tokens * p_in + output_tokens * p_out - cache_discount)
```

Token budgets [I]: draft output 2-6K tokens (up to ~8K for complex scenes); a 768 px image is roughly 0.8-1.0K input tokens; each critique call carries the SVG as input and returns a revised SVG as output, so about 3-8K output. Illustration: with an assumed placeholder of $3 per Mtok in and $15 per Mtok out (not the catalog prices; check `Catalog.pricesOf`), a balanced run with 1 draft (1.5K in, 5K out) and 1 critique (7K in, 5K out) costs about 3 * 8.5e-3 + 15 * 10e-3... i.e. roughly $0.18 before markup at those assumed prices. Recraft: about $0.05-0.08 direct plus markup [S]. Replace these with real numbers from `usage_events` over the eval set before setting caps.

Prompt caching: the design prompt and presets go after the constant prefix; critique calls reuse the draft's prefix, so Anthropic cache reads apply [I].

### 5.5 Editing UX
Phase 1 (no new editor): edits are chat requests applied with `edit_artifact` on stable ids ("make the sky warmer"), versioned by the existing artifact history.
Phase 2: click an element in the svg panel to select it by id and prefill the composer ("change #wing-left ..."); a palette panel listing unique fill/stroke values with a swap action that rewrites the source; an inline field for `<text>` nodes.
Phase 3 (only if demand): layer list from `<g id>` with visibility toggles. Skip a full node editor; Excalidraw does not edit arbitrary SVG paths, so keep it for diagrams.
Every edit re-runs `check_svg` so the model and user never see a broken artifact.

### 5.6 Exports
- SVG as saved (exists), cleaned by `sanitizeSvg`.
- PNG: scale picker 1x/2x/4x and transparent background. The client path is capped at 480pt wide; add a server-rendered resvg PNG for sharper large output.
- PDF/DOCX/PPTX: already use the client raster. A vector PDF is a later upgrade if `pdf_writer` can embed paths.
- Fonts: embed or convert text to paths on export to avoid renderer differences [I].

### 5.7 Model choice
Default Sonnet 5.5 for drafts. Opus 5.5 for "best". Haiku 5.5 for fast icons and for critique if its defect lists are good enough (eval decides). Recraft for illustration engine. Prefer a model that accepts image input for critique (catalog `input_modalities`). Do not rely on any claim about how Claude's own artifact SVG works internally; no public statement was found [I].

## 6. Eval plan

Goal: decide prompt version, engine and critique-round count by data. Run headless next to `frontend/tool/agent_eval` (or in backend-exp tests).

Method: each prompt run under conditions A one-shot (current prompt), B design prompt, C design prompt + 1 critique, D + 2 critiques, E Recraft; across Haiku/Sonnet/Opus for A-D. 3 samples per cell for variance.

Scoring rubric (per output):
- Gate: parses and renders in resvg (pass/fail). Also renders in flutter_svg (catch divergence).
- VLM judge on the PNG, 1-5 each: prompt match, recognizability, composition, color harmony, polish, defects (inverse: detached parts, hidden shapes, clipped content). Use a different vendor model than the generator where possible; run pairwise (A vs B) with order swapped to cut position bias.
- Objective: byte size, path count, token cost, wall time, charged_micros.
- Optional automatic: CLIP or DINO similarity to the prompt/reference (SGP-GenBench/CTRL-S style) [S].
- Human spot-check of 10 outputs per release.

Decision rule: ship the critique round if pass rate or judge score gains at least 0.5 points over B at under 2x cost; ship Recraft engine for the illustration buckets if it beats C by 0.5 points.

Twenty sample prompts:

Icons
1. A 24 px line icon of a calendar with a checkmark.
2. A set of three flat icons: cloud upload, shield, key (same style).
3. A rounded app icon of a paper plane, purple gradient.

Logos
4. A geometric logo for a coffee roaster called "Ember", one color.
5. A monogram logo "AK" inside a hexagon, two colors, works at 32 px.
6. A minimal wordmark "Northwind" with a wind-swirl in the N.

Flat illustrations
7. A red fox curled up sleeping on autumn leaves.
8. A lighthouse at dusk with waves and a few stars.
9. A friendly robot waving, flat style, four colors.
10. A bicycle leaning against a brick wall.

Scenes
11. A mountain lake at sunrise with pine trees and mist layers.
12. A cozy reading nook with a window, plant, lamp and cat.
13. A city skyline at night with lit windows and a moon.

Posters and patterns
14. A retro travel poster for a fictional desert town, big sun, no text.
15. A seamless-feeling geometric pattern in teal and coral.
16. A sticker of a smiling avocado with sunglasses.

Diagrams and figures
17. An isometric diagram of a three-tier web architecture.
18. A labeled cross-section of a plant cell with 6 organelles.
19. A pie-and-legend style infographic of a monthly budget (5 categories, with numbers).

Edits (second turn)
20. Take output 8 and change it to daytime, make the lighthouse red and white striped, keep everything else.

Expected hard cases: 6, 18, 19 (text), 10 and 12 (spatial consistency), 15 (tiling), 20 (edit stability).

## 7. Roadmap

1. Week 1: design prompt section + `render_svg`/`create_artifact` description update, stable ids; presets; (backend-exp `tools.zig`). No infra.
2. Week 1-2: eval harness with prompts above and the render gate; baseline numbers for conditions A and B.
3. Week 2-3: `render.zig` calling the resvg CLI (static binary shipped with the backend); `check_svg`; validation inside the tool loop; fix the resvg license line in the media doc.
4. Week 3-4: `generate_vector` with critique rounds, budgets, `tool_status` and `usage_events` kinds; app shows progress; re-run eval, set defaults.
5. Week 4-5: Recraft engine through the planned `images.zig` rewrite to `/api/v1/images`; result through `check_svg`.
6. Later: PNG export options, element selection and palette panel, vtracer vectorize, svgo or a Node worker if size matters, best-of-N with a VLM judge for the Max plan, self-hosted models only if GPUs arrive.

## 8. Unverified

- All paper and benchmark claims (CTRL-S, VectorGym, SGP-GenBench, IntroSVG and others) are from search snippets. No paper was opened.
- Chat2SVG stages 2-3 are described from README and directory names. No LICENSE file exists in the clone; the upstream repo was not checked.
- Full LICENSE texts for svgo, vtracer, SVGDreamer and VectorFusion-pytorch were not read past the first lines; weights and dataset licenses (StarVector, OmniSVG weights, SVG-Sophia) were not checked.
- Recraft slugs, prices and resale terms come from prior research (`generation-providers.md`) and were not re-fetched.
- No resvg, svgo or vtracer run was done; font handling, filter and gradient fidelity versus flutter_svg are untested.
- Model prices for Haiku/Sonnet/Opus 5.5 were not verified; the dollar example in 5.4 uses placeholders.
- The effect of the critique loop on current models is unmeasured; Chat2SVG's gains were on older models.
- LLM4SVG, SVG-Bench, SVGEditBench were not located.
- Claude's internal method for SVG artifacts is not publicly documented to my knowledge.
- This pass did not run the Sonnet 5.5 workflow as a separate subagent job; findings come from the scout's clones and the repo.

## Appendix: connectors (short; the same research pass)

Scope note: the scout's map is not verified beyond WebFetch summaries. Facts and proposals:
- Claude custom connectors are remote MCP servers over HTTPS, reached from Anthropic's cloud, with OAuth or static headers [S: support.claude.com 11175166]. The API MCP connector beta takes `mcp_servers` + `mcp_toolset`, public Streamable HTTP/SSE only [S: platform.claude.com docs].
- Reference code to copy (licenses): `google_workspace_mcp` auth layer (MIT), `github-mcp-server` toolset grouping and schema snapshots (MIT), `arcade-mcp` tool-declares-scopes model (MIT), `composio` (MIT, unexplored). Nango is Elastic License 2.0: design reference only. Activepieces licence unconfirmed: check before copying.
- EveryAI options: (A) forward `mcp_servers` on the Anthropic route only; (B) provider-neutral: backend-exp as MCP client over Streamable HTTP, merging tools into the loop as server tools, appended last to keep the system prompt cacheable [I]. An encrypted per-user token vault with rotating refresh tokens fits `auth.zig` [I].
- Vector art does not need MCP in Chat; the Code sidecar could get the resvg check later via `mcp_config` [I]. See also `docs/research/mcp.md`.
