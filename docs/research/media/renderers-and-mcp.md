# Media tooling to reuse: renderers, libraries and MCP servers

Date: 2026-10-30. Scope: SVG, diagrams, charts, math, whiteboard, video, design, MCP registries.

Verification legend: [V] checked this session against a source linked in the Sources section. [K] stated from prior knowledge, not re-checked this session, so confirm license and version before depending on it. [?] unverified or uncertain.

Context (from CLAUDE.md): UI tools are `create_artifact`, `render_svg`, `render_diagram`, `render_chart`, quiz, flashcards, slides. The app renders SVG with flutter_svg, Mermaid from a CDN in a webview, and charts with fl_chart. The backend is Zig on Anole. The Code agent runs on an OpenHands sidecar that supports MCP.

## 0. Core finding

The gaps (no validation, no render-then-look, Mermaid and TeX missing from PDF/Word export) share one cause. All rendering happens in the client, so the model never sees a result and the exporters never get an image. One server-side render service fixes both. It takes `{kind, source}` and returns `{ok, error?, svg, png}`. The chat tool loop calls it before accepting a UI tool call, and the exporters call it for images. Most pieces are permissive (MIT, BSD, Apache). The exceptions that need care are Remotion (company license), tldraw (commercial key), and MPL-2.0 items (resvg, D2, Penpot), which only need source disclosure for modified files.

## 1. Diagram rendering

| Option | What it does | Plug-in | License | Maturity | Effort |
|---|---|---|---|---|---|
| Kroki | One HTTP API that renders about 25 diagram languages (Mermaid, PlantUML, Graphviz, D2, Excalidraw, Vega/Vega-Lite, BlockDiag, Ditaa, etc.) to SVG/PNG. Mermaid and Excalidraw are separate "companion" containers [K] | Docker or sidecar container; Zig POSTs text to `/mermaid/svg`. Errors come back as HTTP 400 with a message the model can use | MIT [K] | Mature, widely deployed | Low if you can ship a container. Heavy for a desktop app (Java gateway + Node + headless Chromium for Mermaid) |
| mermaid-cli (`mmdc`) | Official Mermaid to SVG/PNG/PDF via Puppeteer | Sidecar Node process or per-call subprocess | MIT [K] | Mature, but needs headless Chromium (about 300 MB) | Low to medium |
| mermaid.parse (mermaid JS, no browser) | Syntax validation only (`mermaid.parse`). Rendering needs a DOM | Run in a Node/Bun script, or in the webview with an error callback | MIT [K] | Mature | Very low; validation only |
| mermaid.ink | Public hosted renderer (base64 diagram in URL) | Zig HTTP GET | Hosted service, no SLA [?] | Works, but sends user content to a third party | Very low; rejected for privacy |
| Mermaid in the existing webview | Already used (CDN) | Add an error channel back to Dart, and bundle `mermaid.min.js` as an asset for offline use | MIT [K] | Existing | Low. Gives validation and a screenshot only while a webview is mounted |
| D2 | Modern declarative diagram language with a Go binary. Output to SVG/PNG | Single static binary subprocess | MPL-2.0 [K] | Mature | Low (one binary, no browser) |
| Graphviz | `dot` layout, SVG output | Static binary or WASM (viz.js / @hpcc-js/wasm) | EPL-1.0 for Graphviz, MIT for viz.js [K] | Very mature | Low |
| PlantUML | UML diagrams, Java | Via Kroki, or the jar | GPL-3 or LGPL, depends on distribution [K] | Mature | Avoid bundling; use via Kroki as a separate process if wanted |

Notes. Mermaid needs a DOM for layout, so every route to a server-side render requires a headless browser (Kroki's companion, mermaid-cli) or a JS runtime with jsdom. [K] Mermaid also has an ELK layout plugin; check its license before using it.

## 2. SVG tooling

| Option | What it does | Plug-in | License | Maturity | Effort |
|---|---|---|---|---|---|
| resvg / usvg (Rust) | Strict SVG parser (usvg) and rasterizer (resvg). Reports parse errors, resolves styles, outputs PNG | A C API exists (`resvg-capi`). It can link from Zig (`@cImport`) or run as a CLI. It is static and has no browser dependency | MPL-2.0 [K] | Mature, high test coverage | Low to medium. The best "does my SVG parse and what does it look like" check |
| svgo | Optimizer, also removes scripts with plugins | Node script | MIT [K] | Mature | Low, not needed if resvg is used |
| Sanitizers (DOMPurify with the SVG profile, or resvg's own rejection of scripts and external refs) | Strip `<script>`, `on*` handlers, `foreignObject`, external hrefs | DOMPurify in Node/webview; resvg ignores scripts by design [K] | Apache-2.0 or MPL-2.0 (DOMPurify) [K] | Mature | Low. Our Dart sanitizer can stay for the client |
| librsvg | GNOME renderer, C library | Link from Zig | LGPL-2.1+ [K] | Mature | Worse licensing than resvg for static linking |
| Skia / resvg via Flutter | flutter_svg already renders in the app | Existing | MIT [K] | Existing | Free, but it does not report failures to the model |

Recommendation: resvg is the server-side validator and rasterizer for SVG, and the final PNG for DOCX/PDF/PPTX exports. flutter_svg stays for the live display.

## 3. Chart specs

| Option | What it does | Plug-in | License | Maturity | Effort |
|---|---|---|---|---|---|
| Vega-Lite (vega, vega-lite) | Declarative JSON grammar. The `vega` library renders SVG/PNG on Node without a browser (`view.toSVG()`) [K] | Node sidecar, or run through Kroki. It also validates against a JSON schema | BSD-3-Clause [K] | Very mature. Models know it well | Medium. A good replacement for our bespoke `render_chart` schema, or an added `vega_lite` kind |
| Apache ECharts | Rich interactive charts. Server-side SVG rendering exists (`renderToSVGString`, no DOM) [K] | Node sidecar; also embeddable in the webview | Apache-2.0 [K] | Very mature | Medium |
| AntV mcp-server-chart (antvis) | MCP server with 25+ chart tools (the family of `generate_*_chart`); returns a PNG/SVG URL via AntV's hosted GPT-Vis-SSR by default [K][?] | MCP for the Code agent. Self-hosting the renderer is possible [?] | MIT [K] | Active, popular | Low for MCP use. The hosted renderer sends data to a third party, so host your own |
| Chart.js | Canvas charts, needs a canvas (node-canvas) to rasterize on a server | Webview | MIT [K] | Very mature | Not worth it; no SVG |
| Observable Plot / D3 | JS, SVG output | Node + jsdom | ISC / BSD-3 [K] | Mature | Models write D3 well, but the output is arbitrary code, which is harder to sandbox |
| fl_chart (current) | Dart renderer, native | Existing | MIT [K] | Existing | No server-side render; no PDF export unless drawn separately |

Recommendation: keep fl_chart for simple charts. Add a `vega_lite` kind, validated and rendered by the render service, because that fixes chart export and gives models a format they know. ECharts is second choice when interactivity is wanted.

## 4. Math

| Option | What it does | Plug-in | License | Maturity | Effort |
|---|---|---|---|---|---|
| KaTeX | Fast TeX to HTML/MathML. HTML output needs its CSS and fonts, so it is not directly SVG | Node `katex.renderToString` is useful for validation (it throws `ParseError`) | MIT [K] | Very mature | Very low for validation |
| MathJax v3/v4 (mathjax-node successor `mathjax-full`) | TeX to standalone SVG without a browser, via liteDOM adaptor | Node script; SVG goes into PDF/DOCX as an image (or into OMML for Word) | Apache-2.0 [K] | Very mature | Low to medium |
| temml / latex2mathml | TeX to MathML, then Word can import OMML through the MML2OMML stylesheet | Needs XSLT; exports only | MIT [K][?] | Mature | Medium. Gives native, editable Word equations |
| flutter_math_fork (in use) | Dart renderer in the app | Existing | MIT [K] | Existing, has the DryBaseline issue (see CLAUDE.md) | No export |

Recommendation: MathJax for SVG-to-PNG in PDF/DOCX exports. KaTeX `ParseError` for fast validation if a JS runtime is present. Native Word equations (OMML) are a later nicety [?].

## 5. Drawing and whiteboards

| Option | What it does | Plug-in | License | Maturity | Effort |
|---|---|---|---|---|---|
| Excalidraw | Hand-drawn whiteboard. React component `@excalidraw/excalidraw`, JSON scene format, export to SVG/PNG. Mermaid-to-Excalidraw converter exists [K] | Webview page with the component; model emits scene JSON or Excalidraw's "skeleton" element API. Server-side export via Kroki [K] | MIT [K] | Very mature | Medium. Best open option for an editable drawing canvas |
| tldraw | Polished infinite canvas SDK with an AI "make real" lineage and an agent starter kit | Webview with the React SDK | Custom tldraw SDK license, not OSI. Production needs a license key. Hobby keys keep the "made with tldraw" watermark and are discretionary. Commercial pricing is by sales [V] | Mature, active | Not recommended for a paid product without a deal |
| Excalidraw MCP servers (community, and the official `excalidraw/excalidraw-mcp` [?]) | Let agents draw scenes, with a live canvas | MCP for the Code agent | MIT [K][?] | Young; verify before relying on it | Low |
| draw.io / diagrams.net (jgraph) | Mature diagramming. There is an official draw.io MCP [?] | Webview (embed mode) | Apache-2.0 [K] | Very mature | Medium. Better for formal diagrams than sketches |
| Flutter-native canvas | Own painting with `CustomPainter` / `flutter_drawing_board` | Pure Dart | MIT [K][?] | Small packages | Medium. Gives no model-generated drawing format |

Recommendation: Excalidraw in the webview for "draw" requests. The model emits scene JSON, validated by the render service (Kroki's Excalidraw renderer, or the `exportToSvg` function in the webview).

## 6. Video

| Option | What it does | Plug-in | License | Maturity | Effort |
|---|---|---|---|---|---|
| Remotion | React compositions rendered to MP4 via headless Chromium + ffmpeg. Models write it well | Node + Chromium sidecar; Code agent | Not OSI. Free for individuals, non-profits and for-profits with up to 3 employees; companies of 4 or more need a paid Company License. The license text says Remotion 5.0 will slightly change terms (not checked whether it shipped) [V]. Paid tiers are described inconsistently across pages ($25 per seat per month for Creators vs $100 per month for Automators) [V][?] | Mature, very active | Medium. Commercial exposure, because EveryAI would be a product that renders video for customers; likely needs a license |
| Revideo | Fork of Motion Canvas for programmatic video, with an API and headless renders | Node sidecar | MIT [K] | Active, smaller [?] | Medium. Permissive alternative to Remotion |
| Motion Canvas | TypeScript generator-based animation editor and renderer | Node + browser | MIT [K] | Mature, hobby-sized | Medium |
| Manim Community Edition | Python math animations (3Blue1Brown style); Cairo + LaTeX + ffmpeg | Python sidecar; Code agent. Heavy deps (TeX) | MIT [K] | Very mature. Models know the API | Medium to high on install size and LaTeX |
| ffmpeg | The base layer: encode, concat, subtitles, trim | CLI subprocess from Zig or the sidecar. ffmpeg MCP servers exist [K][?] | LGPL-2.1+ or GPL-2+, depending on build flags. Use LGPL builds without `--enable-gpl` and without x264 for distribution [K] | Very mature | Low |
| HTML-to-video (record a page with Playwright/Puppeteer frame capture + ffmpeg) | Any animated HTML becomes an MP4. HeyGen's open-source "HyperFrames" is of this kind [?] | Node + Chromium | Not verified [?] | Young [?] | Medium. Verify the project and its license before use |
| Hosted video model (via OpenRouter, if offered) | Text-to-video generation | Zig client, as for `/v1/images` | Provider terms [?] | Varies | Low, but costly per clip |

Recommendation: do not build a first-class video tool in the first pass. For the Code agent, install ffmpeg plus Manim or Revideo through the sidecar. Treat Remotion as a "license required" option. When a product feature is wanted, prefer Revideo (MIT) or the HTML-capture route.

## 7. Design and UI generation

| Option | What it does | Plug-in | License | Maturity | Effort |
|---|---|---|---|---|---|
| Penpot MCP | Official server (free and open source per Penpot). Hosted and local modes. The current tool is `execute_code` against the Penpot plugin API. Active in one browser tab at a time [V] | MCP for the Code agent | Penpot is MPL-2.0 [K]. The MCP license is stated as open source [V], exact license not checked [?] | New, evolving | Low for the agent. Product embedding is high |
| Figma MCP (Dev Mode server, and Figma's remote server) | Reads design context, variables and code. Newer versions can write to canvas [?] | MCP for the Code agent; needs a Figma account | Proprietary service [K] | Mature for reading | Low. Useful for users who already use Figma |
| Playwright MCP (microsoft/playwright-mcp) | Browser automation by accessibility snapshots, with screenshots | MCP for the Code agent: the render-then-look check for web UI | Apache-2.0 [K] | Very mature, official Microsoft | Low. High value for Code |
| Chrome DevTools MCP (Google) | Debugging and screenshots via CDP | MCP for the Code agent | Apache-2.0 [K] | Active | Low. Alternative to Playwright |
| Preview inside our webview | `flutter_inappwebview` is already used for Preview pane in the Code plan | Add a `screenshot()` call and return an image to the model | MIT [K] | Existing | Low. Works without Chromium on mac/win/iOS/Android; not on Linux |
| Component generators (shadcn/ui, v0-style, Tailwind) | Models generate React/HTML | Output as an `html` artifact in the panel; add a screenshot check | MIT [K] | Mature | Low |
| Google Stitch, Locofy and similar | Hosted UI generation | Not open source [K][?] | Proprietary | Not relevant | Skip |

## 8. MCP registries and the lookup path

| Source | Notes |
|---|---|
| `modelcontextprotocol/servers` (GitHub) | The reference set. Most media servers (Puppeteer, Fetch) were moved to an archive and are community-maintained now [K][?]. Not a source for media servers |
| Official MCP Registry (registry.modelcontextprotocol.io) | Preview-stage metadata registry for servers [K][?] |
| `punkpeye/awesome-mcp-servers`, `wong2/awesome-mcp-servers`, Smithery, Glama, PulseMCP | Community lists; review each server before use |
| Notable servers found or recalled: antvis/mcp-server-chart, microsoft/playwright-mcp, Penpot MCP, Figma MCP, Excalidraw MCP, mermaid MCP servers (e.g. `mcp-mermaid`, which uses mermaid-cli/Playwright [?]), ffmpeg MCP servers | Check each repo's license and last commit |

MCP only helps the Code agent today (OpenHands supports `mcp_config`, see CLAUDE.md). The chat flow does not use MCP, so chat must call our own Zig render service.

## 9. Ranked: adopt these

1. **resvg (C API or CLI)**: SVG validate and rasterize, plus the PNG for exports. MPL-2.0, low effort. Fixes gaps 1 and 2 for SVG.
2. **Render service with Mermaid via a headless browser**: first use mermaid-cli (or Kroki's Mermaid companion). Start with a lazy-started sidecar that is optional. Returns parse errors to the model and SVG/PNG to exporters. Fixes the Mermaid half of the export gap.
3. **MathJax (SVG) and KaTeX `ParseError`**: math validation and export images. Same Node process as item 2.
4. **Vega-Lite via the `vega` package**: a chart kind that renders without a browser and validates against a schema. Keep fl_chart as the fast native path.
5. **Playwright MCP in the Code agent's `mcp_config`**: screenshot-based verification of generated UIs. Zero backend work.
6. **Excalidraw in the webview**: the drawing canvas. MIT. Scene JSON validated by the render service.
7. **ffmpeg plus Revideo or Manim for the Code agent only**: video without a licensing problem. Defer a product feature. Avoid Remotion without a license decision; avoid tldraw without a deal.
8. **Penpot MCP and Figma MCP**: optional connectors for the Code agent.

## 10. Proposed architecture: one render service

```
chat.zig tool loop ──► POST /internal/render {kind: svg|mermaid|math|vega|excalidraw, source}
exporters (PDF/DOCX/PPTX) ──►        same endpoint, asks for png
                                     │
        Zig (Anole) handler ─────────┼─ svg   -> resvg (linked C API): validate, return error text or PNG
                                     ├─ mermaid / math / vega / excalidraw
                                     │      -> render-worker (Node/Bun, optional sidecar, lazy start)
                                     │         mermaid-cli + headless Chromium, mathjax-full, vega, excalidraw export
                                     └─ cache by sha256(kind, source), returns {ok, error, svg, png_base64}
```

- Feedback loop: `render_svg`, `render_diagram` and the other visual tools become server tools. If the render fails, the tool result is `{error: "..."}` and the model fixes its source in the same turn. Optionally, the PNG is returned as an image part so the model can look at it (render-then-look). Cost: one extra image-bearing call; limit to one retry [?].
- Exports: the PDF and Word writers fetch PNG (or SVG) for each diagram or equation from the same cache. The slides to PPTX writer can use it too.
- Packaging: resvg is in-process. The Node worker plus Chromium is large, so run it only on the hosted backend. The desktop app can use its existing webview (Mermaid + KaTeX) with a Dart-side error callback and `takeScreenshot()`, and skip the worker. [?] Decide whether the backend is hosted or local-only.
- The Code agent gets Playwright MCP, and optionally the render service as an MCP tool over HTTP.
- Security: SVG and diagram sources are untrusted. Strip scripts, `foreignObject` and external references. Mermaid should run with `securityLevel: strict`. Run the worker without network access. [K]

## 11. Open questions for the user

1. Will chat rendering live on the hosted backend (a Node and Chromium worker is fine) or must it work offline on the desktop? This decides between the sidecar worker and webview-only validation.
2. Is video a product feature or only a Code-agent capability? If a product feature, the Remotion license cost (or Revideo) must be decided.
3. Is a single heavyweight dependency (Chromium) acceptable in the backend's container?

## Sources

- tldraw license key and SDK license: https://tldraw.dev/sdk-features/license-key and https://tldraw.dev/legal/tldraw-license [V]
- Remotion license: https://remotion.dev/license and https://github.com/remotion-dev/remotion/blob/main/LICENSE.md [V, pricing pages disagree]
- Penpot MCP: https://help.penpot.app/mcp/ and https://penpot.app/ai/mcp-server [V]
- Items marked [K] come from prior knowledge of these projects (GitHub READMEs and license files for Kroki, mermaid-cli, resvg, D2, Graphviz, Vega-Lite, ECharts, antvis/mcp-server-chart, KaTeX, MathJax, Excalidraw, Manim, Motion Canvas, Revideo, ffmpeg, Playwright MCP). They were not re-fetched in this pass, so confirm each license file and release date before adoption.
- Not cloned: nothing was cloned into /private/tmp/claude-501/media-research/.
