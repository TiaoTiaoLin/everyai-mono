# Media: what to reuse instead of build (2026-10-30)

Three studies:
- [chat-apps.md](chat-apps.md): how open chat apps do media, and what their licenses allow.
- [renderers-and-mcp.md](renderers-and-mcp.md): rendering services and libraries, and MCP servers. Most of it is from prior knowledge, tagged `[K]`; recheck licenses before adopting.
- [generation-providers.md](generation-providers.md): image, SVG and video providers, with pricing.

## Use this, don't build it

| Need | Reuse | License | How it plugs in | Effort |
|---|---|---|---|---|
| Image gen + edit + reference images | OpenRouter `POST /api/v1/images` (`input_references`, `n`, `output_format`) | service | Rewrite `backend-exp/src/images.zig` to call it; add references to `generate_image` | S |
| Real SVG from an image model | OpenRouter `recraft/recraft-v4*-vector` (`output_format:"svg"`); Recraft direct for vectorize | service | `generate_svg` tool or an SVG option on images | S |
| Video | OpenRouter `POST /api/v1/videos` (async job + webhook); default `google/veo-3.1-fast`, cheap Kling/Wan, edit with `runway/aleph-2` | service | New `videos.zig` + `video_jobs` table, `/v1/videos`, a job card in the app | M |
| SVG validation + raster (live feedback, exports) | resvg C API | Apache-2.0 OR MIT | Link from Zig: a render service returning `{ok, error, png}` | M |
| Mermaid validation + PNG | mermaid-cli (Node + headless Chromium), or LibreChat's webview export code | MIT | A lazy worker in the backend; or a PNG export from our existing webview page | M |
| Math to SVG | MathJax (server) / KaTeX `ParseError` to validate | Apache-2.0 / MIT | Same worker | S |
| Data charts with server render | Vega-Lite | BSD-3 | New chart kind; keep fl_chart as the native path | M |
| Drawing canvas | Excalidraw (+ mermaid-to-excalidraw) | MIT | `drawing` artifact in the webview | M |
| Artifact edit prompts and the find-and-replace edit tool | Vercel ai-chatbot `editDocument`; LibreChat artifact prompt | Apache-2.0 / MIT | We shipped `edit_artifact` (dc3c90c); borrow the prompt rules | S |
| Code agent: charts, draw.io, UI screenshots, design | antvis/mcp-server-chart, jgraph/drawio-mcp, Playwright MCP, Penpot MCP | MIT / Apache-2.0 / Apache-2.0 / MPL | OpenHands `mcp_config`, no backend work | S |
| Design/UI generation check | Our webview: render, screenshot, model critique | — | Render-then-look loop; no open pipeline verifies output | M |

## Avoid (license)
- **Code to avoid copying:**
  - Open WebUI (branding clause)
  - LobeChat (commercial license for derivatives)
  - Cherry Studio (AGPL)
  - Dify (modified license)
- **Products to avoid depending on:**
  - Remotion: free only up to 3 employees; prefer Revideo (MIT), Manim or ffmpeg
  - tldraw: needs a paid key and watermarks without one
  - OpenAI Sora API: being retired (unverified)

## Open decisions
- **Where the render worker runs.** Mermaid and math need a DOM. Options are a hosted backend with headless Chromium, or the app's own webview, which also works offline.
- **Whether video is a product feature.** If so, it needs its own pricing on the plans and a decision on cost previews.
