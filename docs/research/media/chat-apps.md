# Media features in open-source chat apps and agent products: what EveryAI can reuse

Date: 2026-10-30. Slice: chat apps and agent products. Shallow clones are in `/private/tmp/claude-501/media-research/<name>`.
Paths below are relative to those clones. Items marked **(unverified)** came from memory or web snippets, not from source I read.

## 0. Licenses at a glance (the filter for everything below)

| Project | License | Verdict for EveryAI |
|---|---|---|
| Vercel ai-chatbot | Apache-2.0 (`chatbot/LICENSE`) | Copy freely, with notice |
| LibreChat | MIT (`LibreChat/LICENSE`) | Copy freely |
| bolt.diy | MIT (`bolt.diy/LICENSE`) | Copy freely, but WebContainer API is proprietary (see Code) |
| Onlook | Apache-2.0 (`onlook/LICENSE.md`) | Copy freely |
| AnythingLLM | MIT (GitHub API) | Copy freely; features are thin |
| OpenHands | MIT core, enterprise dir separate (GitHub API) | Already our sidecar |
| Excalidraw, mermaid-to-excalidraw | MIT (GitHub API) | Embeddable |
| mermaid-cli | MIT (GitHub API) | Server-side render, needs headless Chromium |
| antvis/mcp-server-chart, GPT-Vis | MIT (GitHub API) | Chart-render service/lib |
| jgraph/drawio-mcp | Apache-2.0 (GitHub API) | draw.io diagrams via MCP |
| tldraw/make-real | repo has no LICENSE file (prompts only; code depends on tldraw) | Prompts are ideas only; do not copy code. tldraw SDK 4.x needs a paid key and a watermark in production ([tldraw.dev/sdk-features/license-key](https://tldraw.dev/sdk-features/license-key)). Avoid |
| **Open WebUI** | Custom BSD-3 with a **branding-preservation clause** (`open-webui/LICENSE` lines 14-20: no removing "Open WebUI" branding above 50 users) | Do not copy code. Read for ideas only |
| **LobeChat / LobeHub** | **LobeHub Community License** = Apache-2.0 plus "derivative works need a commercial license" (`lobe-chat/LICENSE`) | Do not copy code. Read for design only |
| **Cherry Studio** | **AGPL-3.0** (GitHub API) | Do not copy |
| Dify | Modified Apache with multi-tenant and logo restrictions (GitHub API: NOASSERTION) **(unverified in detail)** | Call as a service at most; do not copy |
| Jan | NOASSERTION in GitHub API; I believe Apache-2.0 / AGPL mix **(unverified)** | Skip |
| excalidraw-mcp | no license declared (GitHub API: None) | Do not copy |

## 1. SVG illustrations

| Project | How | Library | License | Reuse path | Effort |
|---|---|---|---|---|---|
| LibreChat | `image/svg+xml` artifact type. The prompt requires "one `<svg>` element with a `viewBox`" and says to offer an SVG when asked for an image (`LibreChat/packages/api/src/prompts/artifacts/index.ts:10,28`) | Sandpack preview (iframe); no server validation found | MIT | Copy the two prompt lines. We already render SVG with flutter_svg plus a sanitizer | S |
| Vercel ai-chatbot | No SVG type. Artifact kinds are code/text/sheet/image (`chatbot/artifacts/*`) | none | Apache-2.0 | Nothing | n/a |
| Open WebUI | SVG inside HTML artifacts and code blocks, rendered in an iframe; the sandbox attribute is a user setting (`open-webui/src/lib/components/chat/Artifacts.svelte:260`). Uses dompurify (`package.json:110`) | iframe + dompurify | custom, flagged | Idea only: allow-scripts toggle | n/a |
| LobeChat | `html-artifact` and `builtin-tool-canvas` packages. The canvas tool is create/update/read with versions, plus a mandatory `readCanvasGuide` call, and a rejected save returns a list of problems to fix (`lobe-chat/packages/builtin-tool-canvas/src/systemRole.ts`). That validate-then-retry loop is the interesting part | n/a | flagged | Idea: server-side validate on `render_svg` and return errors to the model | M |

None of these validate or rasterize SVG on the server. The gap stays open; see section 3 for the render-then-look pattern.

## 2. Diagrams (Mermaid and others)

| Project | How | Library | License | Reuse path | Effort |
|---|---|---|---|---|---|
| LibreChat | Mermaid fences render in chat. Also an `application/vnd.mermaid` artifact. The artifact prompt says a short diagram goes in a mermaid fence. Mermaid initialised with `securityLevel: "strict"` (`LibreChat/client/src/utils/mermaid.ts:464`). **Export**: `utils/diagram/export.ts` post-processes the rendered SVG (`processMermaidSvg`, `applyMermaidBackground`), then downloads SVG or a 2x PNG through a canvas (`export.ts:4,58,109,139-211`). Zoom/pan dialog in `components/Messages/Content/Mermaid/*` | mermaid ^11.17.2 (`client/package.json:99`) | MIT | **Copy the SVG-fixup + PNG export logic** into our webview page (JS). We already host Mermaid in InAppWebView; add a "export PNG/SVG" JS bridge. For PDF and Word, embed the PNG/SVG into the document exporter | S-M |
| Open WebUI | `initMermaid` / `renderMermaidDiagram` in `src/lib/utils/index.ts:2155,2305`, `securityLevel: 'loose'` and `htmlLabels: false`. The `loose` setting is less safe than LibreChat's `strict` | mermaid ^11.17.2 | custom, flagged | Take `htmlLabels:false` as a hint (it avoids foreignObject, which breaks canvas PNG export). Idea only | S |
| Excalidraw / mermaid-to-excalidraw | Converts Mermaid to editable Excalidraw scenes ([excalidraw/mermaid-to-excalidraw](https://github.com/excalidraw/mermaid-to-excalidraw), MIT). Excalidraw's own text-to-diagram (TTD) dialog calls a hosted LLM; license of TTD backend **(unverified)** | @excalidraw/mermaid-to-excalidraw | MIT | Use as "edit this diagram" path; see Drawing | M |
| mermaid-cli | Headless render of Mermaid to SVG/PNG/PDF with puppeteer. Not in a chat app but the standard server-side validator | @mermaid-js/mermaid-cli | MIT | **Sidecar or tool service**: `mmdc` run by our Zig backend (or in the agent-server) to validate syntax and render PNG/PDF. Needs Chromium (~150 MB) | M |
| jgraph/drawio-mcp | MCP server that lets agents create draw.io diagrams | n/a | Apache-2.0 | MCP tool; OpenHands supports `mcp_config`, so the Code agent can use it | S (Code only) |
| Vercel ai-chatbot, AnythingLLM, bolt.diy | No Mermaid feature found in clones (grep of `bolt.diy/app`, `chatbot`) | n/a | n/a | n/a | n/a |

## 3. Charts

| Project | How | Library | License | Reuse path | Effort |
|---|---|---|---|---|---|
| LibreChat | React artifacts may import `recharts` (`prompts/artifacts/index.ts`: allowed imports list) | recharts in Sandpack | MIT | Not applicable to Flutter. Only the prompt idea | n/a |
| Vercel ai-chatbot | `sheet` artifact (spreadsheet) instead of charts; chart tools in the docs are weather demos | react-data-grid **(unverified)** | Apache-2.0 | none | n/a |
| LobeChat | `builtin-tool-dashboard` package exists (name seen only; did not read it) | n/a | flagged | skip | n/a |
| antvis/mcp-server-chart + GPT-Vis | MCP server with ~25 chart tools (line, bar, pie, sankey, word cloud, mind map, fishbone, flow...). Renders through AntV GPT-Vis, optionally to a PNG URL **(unverified, from README memory)** | AntV | MIT | **Service/MCP**: the Code agent can use it. For chat, our `render_chart` schema could borrow the chart-type list. fl_chart has no sankey or mind map | S for MCP; L to port types |

Chat apps mostly punt on charts and let the model write a React or HTML artifact. Our native `render_chart` is already ahead of most of them.

## 4. Image generation and editing

| Project | How | Providers | License | Reuse path | Effort |
|---|---|---|---|---|---|
| Open WebUI | One router with pluggable engines: `openai`, `gemini`, `comfyui`, `automatic1111`, plus an edit endpoint (`comfyui_edit_image`) (`open-webui/backend/open_webui/routers/images.py:37-43,177-211,343-421,627`) | OpenAI, Gemini, ComfyUI workflows, A1111 | custom, flagged | Idea only. Good design reference for an optional "bring your own ComfyUI" later | n/a |
| LobeChat | `builtin-tool-image-generation` as a model-callable tool, with a provider/model listing step | many (Fal, OpenAI, etc. **unverified**) | flagged | Idea: expose `list_image_models` so the model can choose | S |
| Vercel ai-chatbot | `image` artifact kind that shows an image with versioning and copy (`chatbot/artifacts/image/client.tsx`) | AI SDK image models | Apache-2.0 | Pattern: treat generated images as versioned artifacts in the panel, so edits are new versions. Cheap to copy in concept | S |
| tldraw make-real | Sketch to HTML only, not image gen | n/a | n/a | n/a | n/a |

We already call OpenRouter image models through `/v1/images`. Nothing here beats that; the gain is UX (versions, edit-in-place, model listing).

## 5. Video

| Project | How | License | Reuse path | Effort |
|---|---|---|---|---|
| LobeChat | `builtin-tool-video-generation` with API calls `listVideoModels`, `getVideoModelParameters` (call before model-specific params), and `generateVideo`. Providers named in the schema: lobehub, volcengine, google (`lobe-chat/packages/builtin-tool-video-generation/src/manifest.ts:5-45`) | flagged (do not copy) | **Copy the shape, not the code**: three tools (list, params, generate) with async job polling. Implement in Zig against OpenRouter video models or Google Veo / Seedance directly **(provider availability unverified)** | M |
| Others | No video feature found in Open WebUI, LibreChat, Vercel, bolt.diy, Onlook | n/a | n/a | n/a |

## 6. Drawings and whiteboards

| Project | How | Library | License | Reuse path | Effort |
|---|---|---|---|---|---|
| tldraw make-real | User draws on a tldraw canvas, the app sends a screenshot plus a system prompt to a vision model, and the HTML result is shown in an iframe shape (`make-real/app/PreviewShape/PreviewShape.tsx:96-129`; prompts in `make-real/prompts/*.md`) | tldraw 4.x (`package.json:32`) | tldraw custom (paid key in production) | Prompt ideas only ("Red = annotation", fill gaps, Tailwind via CDN, no storage). **Avoid the SDK** | n/a |
| Excalidraw | Embeddable React component; can run in our InAppWebView from a local bundle. Text to scene via mermaid-to-excalidraw or the model emitting Excalidraw JSON | @excalidraw/excalidraw | MIT | **Embed in webview**, new `drawing` artifact kind: model emits Excalidraw element JSON or Mermaid, user edits, we export PNG/SVG (`exportToSvg`). Best answer for "no drawing canvas". Bundle size is a few MB; offline assets are needed | M |
| LobeChat canvas | Report-style page, not a drawing canvas | n/a | flagged | skip | n/a |

## 7. UI and design generation with preview

| Project | How | Library | License | Reuse path | Effort |
|---|---|---|---|---|---|
| LibreChat | Artifact types `text/html` (inline CSS/JS, external scripts only from cdnjs) and `application/vnd.react` (imports limited to react, lucide-react 0.394, recharts, three, date-fns, shadcn/ui) rendered in Sandpack (`prompts/artifacts/index.ts:10-33`; `ArtifactPreview.tsx:2`) | @codesandbox/sandpack-react | MIT | **Copy the prompt block** into our `create_artifact` description (the allowed-imports list and "load only from cdnjs" rule are a good safety and quality guard). Do not adopt Sandpack; our webview already renders HTML | S |
| tldraw make-real | The prompt in `make-real/prompts/anthropic-system-prompt.md` (single HTML file, Tailwind utility classes, vanilla JS, placehold.co images, no localStorage, mobile first) | n/a | prompt text, license unclear | Paraphrase the rules for an "html" artifact style guide | S |
| Vercel ai-chatbot | Artifact tools `createDocument`, `editDocument` (find and replace with `old_string`/`new_string`, `replace_all`), `updateDocument` (full rewrite) and the rule "after creating, never repeat the content in chat" (`chatbot/lib/ai/prompts.ts:4-45`) | AI SDK | Apache-2.0 | **Adopt `edit_artifact` with find-and-replace** next to our `update_artifact`. Cuts tokens on iterations. Copy the prompt rules with attribution | S |
| bolt.diy | Parses `<boltArtifact>` / `<boltAction>` tags from the stream (`bolt.diy/app/lib/runtime/message-parser.ts`, `action-runner.ts`) and runs them in a WebContainer (`@webcontainer/api`, `package.json:113`) | WebContainers (proprietary, browser only) | MIT app, proprietary runtime | Not usable in Flutter. The OpenHands sidecar does this job natively | n/a |
| Onlook | Visual editor for React/Next apps: iframe preview mapped to source via AST, so UI edits write back to code (`onlook/packages/parser`, `code-provider`, `ai`; Apache-2.0) | babel-based parser **(unverified detail)** | Apache-2.0 | Too big to embed. Possible far-future "Design mode" for Code sessions; skip now | XL |
| Open WebUI | HTML artifacts in an iframe with a sandbox attribute driven by a setting (`Artifacts.svelte:260`) | iframe | flagged | Idea: give users an "allow scripts" toggle for HTML artifacts | S |

## 8. Render-then-look verification (closing the loop)

I found no chat app that does this for chat artifacts. Related findings:
- LobeChat Canvas: server-side **validate and return a list of problems** on save (`builtin-tool-canvas/src/systemRole.ts`, workflow step 3). Cheapest form of the pattern.
- bolt.diy: feeds terminal and preview errors back to the model through its action runner **(unverified detail)**.
- OpenHands: has a browser tool, so the Code agent can already screenshot a running app (MIT, already our sidecar).

Recommended EveryAI design (our own): a backend `check_visual` step that runs `mmdc` for Mermaid, `rsvg-convert`/resvg for SVG, and headless Chromium for HTML, returns errors to the model as the tool result, and optionally returns the PNG so a vision model can look at it. Reuse path is a **sidecar binary** (mermaid-cli + resvg), not any chat app's code.

## 9. Export (PDF, Word, PPTX)

| Project | How | Reuse path |
|---|---|---|
| LibreChat | Mermaid SVG/PNG download (see section 2). Artifact download zips files (`components/Artifacts/DownloadArtifact.tsx`) | Copy the Mermaid PNG logic |
| Others | I found no real PDF/Word export of Mermaid or math in any clone | Gap stays ours: rasterize Mermaid to SVG/PNG in the webview, then embed in the PDF/DOCX writer. Math: render with flutter_math to image |

## 10. Ranked "adopt these" list

1. **Vercel ai-chatbot `editDocument` find-and-replace semantics + "don't echo artifact in chat" prompt rules** (Apache-2.0, `chatbot/lib/ai/prompts.ts:4-45`). Small change to `tools.zig`: add `edit_artifact {id, old_string, new_string, replace_all}`. High token savings.
2. **LibreChat Mermaid export logic** (MIT, `client/src/utils/diagram/export.ts`). Port into our Mermaid webview page to get SVG/PNG, and wire that PNG into PDF/DOCX export. Also use `securityLevel: "strict"`.
3. **mermaid-cli (MIT) as a backend sidecar** for server-side Mermaid validation and rendering, returning parse errors to the model (fixes "no server-side validation" and enables render-then-look). Pair with resvg for SVG validation.
4. **Excalidraw embedded in the webview** (MIT) as a `drawing` artifact, with mermaid-to-excalidraw (MIT) for "convert to editable". Fills the whiteboard gap without tldraw's paid license.
5. **LibreChat artifact prompt block** (MIT, `prompts/artifacts/index.ts`): allowed-libraries list, cdnjs-only rule, "SVG needs viewBox", "no placeholder-service URLs". Paste-level reuse into `create_artifact`/`render_svg` descriptions.
6. **LobeChat's video tool shape** (list models, get params, generate; async). Design reference only because the license forbids copying; build it ourselves in Zig.
7. **LobeChat Canvas validate-and-retry loop**, implemented as our own `check_visual` backend step (idea only).
8. **antvis/mcp-server-chart and drawio-mcp as MCP servers for the Code agent** via OpenHands `mcp_config`. Low effort, Code-only.
9. Vercel's image-as-versioned-artifact pattern for generated images.

Do not copy from: Open WebUI (branding clause), LobeChat/LobeHub (commercial-derivative clause), Cherry Studio (AGPL), tldraw SDK (paid key + watermark), Dify (modified license). Reading them for design ideas is fine.

## 11. Not covered or unverified
- Cherry Studio, Dify, Jan, AnythingLLM: judged by license and memory only; I did not clone them.
- Whether Excalidraw's TTD backend is MIT: unverified.
- antvis chart type list and PNG-URL behavior: from memory.
- OpenRouter/Google video model availability and pricing: not checked.
- `dashboard` and `browser` builtin tools in LobeChat: only names seen.
