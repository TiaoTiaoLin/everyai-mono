# Generation providers and open pipelines: image edit, video, design/SVG

Researched 2026-10-30. Convention: [V] = read from an official doc or live API response in this pass;
[3P] = third-party blog or comparison site (treat as approximate); [?] = unverified.
Prices are USD and are upstream cost before our x1.15 markup.

## 0. Headline findings

1. OpenRouter now covers all three capabilities, so the primary stack can stay on one upstream and one key:
   - `POST /api/v1/images` (a dedicated image endpoint, separate from chat completions) with `input_references` for editing and `output_format: "svg"` for vector. [V]
   - `POST /api/v1/videos` (async job, poll or HTTPS webhook). 31 video models listed. [V]
2. Our current `/v1/images` uses the chat-completions `modalities: ["image","text"]` path. That works but cannot do SVG,
   n>1, `quality`, `output_format` or reference lists with per-model limits. Move to `/api/v1/images`.
3. Sora is gone: OpenAI's Videos API and Sora 2 aliases were scheduled for removal on 2026-09-24 (announced 2026-03-24). [3P, several agree; official page not fetched]
4. Veo 3.1 Preview on Google's Gemini API shut down 2026-10-22; Google points to `gemini-omni-1.1-flash` (Interactions API). [V] Veo 3.1 is still routed by OpenRouter (`google/veo-3.1`, `-fast`, `-lite`). [V]
5. SVG-native: six Recraft vector slugs on OpenRouter return real SVG. [V]

## 1. OpenRouter (primary)

### 1.1 Image output and editing [V: openrouter.ai/docs/features/multimodal/image-generation, /api/v1/images/models]

- Request: `POST https://openrouter.ai/api/v1/images`
  `{model, prompt, n(1-10), resolution, aspect_ratio, size, quality, output_format(png|jpeg|webp|svg), background, output_compression, seed, stream, input_references:[{type:"image_url", image_url:{url: https|data:}}], user, provider}`
- Response: `{data:[{b64_json, media_type}], usage}`; `stream:true` gives SSE `image_generation.partial_image|completed|error`.
- Editing = same call with `input_references` (no separate edit or mask endpoint documented; mask/inpaint is prompt-driven) [V that no edit endpoint is documented].
- Billing: all-or-nothing; failed or cancelled returns 502 and is not billed. Per-endpoint pricing at `/api/v1/images/models/{model}/endpoints`
  as `pricing[] {billable: output_image|input_image|input_reference, unit: image|megapixel|token, cost_usd, variant?: 2k|4k}`. (The list endpoint itself carried no prices; fetch per-model.)
- Discovery: `GET /api/v1/images/models` (62 models at fetch time) or `GET /api/v1/models?output_modalities=image`.

| Need | Slugs (max input_references) |
|---|---|
| General gen + edit | `openai/gpt-image-2` (16), `openai/gpt-image-2.5-sunburst|flare` (16), `google/gemini-3.1-flash-image` (14), `google/gemini-nano-banana-2.1` (14), `google/gemini-3-pro-image` (14), `black-forest-labs/flux-3-image` (10), `flux.2-pro` (8), `bytedance-seed/seedream-5-0-pro` (14), `x-ai/grok-imagine-image-2.0` (3), `qwen/qwen-image-3-pro` (3) |
| Edit-first (refs required) | `krea/k3-edit` (1-8) |
| SVG output (`output_format:"svg"`) | `recraft/recraft-v4.1-vector`, `recraft/recraft-v4.1-pro-vector`, `recraft/recraft-v4-vector`, `recraft/recraft-v4-pro-vector`, `recraft/recraft-v4-styles-vector`, `recraft/recraft-v4-styles-pro-vector` |
| Cheap/fast | `google/gemini-3.1-flash-lite-image`, `recraft/recraft-v4.1-flash` (no refs, raster), `qwen/qwen-image-2.1-turbo` |

### 1.2 Video [V: openrouter.ai/docs/features/multimodal/video-generation, /api/v1/videos/models]

- `POST /api/v1/videos` returns 202 `{id, polling_url, status}`; `GET /api/v1/videos/{id}`; `GET /api/v1/videos/{id}/content?index=0`.
- Body: `model, prompt, duration(s), resolution(480p..4K), aspect_ratio, size, frame_images[{frame_type: first_frame|last_frame,...}], input_references[], generate_audio, seed, callback_url(https), provider{options}`. `frame_images` wins over `input_references`.
- Status: `pending | in_progress | completed | failed`. Poll about every 30 s; typical 30 s to several minutes.
- Webhooks: `video.generation.completed|failed|cancelled|expired`; headers `X-OpenRouter-Idempotency-Key` (`<job>-<status>`) and `X-OpenRouter-Signature` (`t=..,v1=..`, HMAC-SHA256 over `"{t},{raw body}"`, reject >5 min old).
- Result: `unsigned_urls` (need `Authorization` header), `urls` (signed, time-limited), `expires_at`, `usage{cost,is_byok}`. Not ZDR-eligible. Docs warn the API may change.
- Pricing: `pricing_skus` map per model (units of dollars per second, or per video token for Seedance). Snapshot of the 31 models [V, `/api/v1/videos/models`]; value units are as returned (seconds-based values read as $/s; `cents_*` as cents):

| Model | Price snapshot | Notes |
|---|---|---|
| `google/veo-3.1` | $0.40/s audio, $0.20/s silent; 4K $0.60/$0.40 | best fidelity, expensive |
| `google/veo-3.1-fast` | $0.12/s audio (720p $0.10) | good default quality tier |
| `google/veo-3.1-lite` | $0.08/s audio (720p $0.05) | cheapest Google |
| `kwaivgi/kling-v3.0-std` / `-pro` | $0.084 / $0.112 per s (audio 0.126 / 0.168) | strong motion |
| `bytedance/seedance-2.0`, `-fast`, `-mini`, `2.5`, `1-5-pro` | per video token ($7.0e-6 per token for 2.0) | convert to $/s per request |
| `minimax/hailuo-3`, `-3-max`, `-2.3` | $0.13 / $0.08 / $0.082 per s | |
| `alibaba/wan-3.0`, `-3.0-prime`, `-2.7`, `-2.6` | $0.05-0.28 per s by resolution | cheapest open-weights lineage |
| `runway/gen-4.5` | 12 cents/s | |
| `runway/aleph-2` | 28 cents/s, min 56 cents | video-to-video edit |
| `black-forest-labs/flux-3-video` | 17-41 cents/s | `flux-video-edit` 3 c/s; `flux-video-upscale` per MP-second |
| `x-ai/grok-imagine-video(-1.5, -1.5-lite)` | 2-25 cents/s by res | |
| `heygen/heygen-video-1`, `heygen/avatar-iv` | per second | avatar/talking-head |
| `alibaba/happyhorse-1.0/1.1`, `tbc/mischief-1`, `kwaivgi/kling-video-o1` | ~0.5-17 c/s | |

[?] Whether OpenRouter's displayed price already includes its own fee, and whether `pricing_skus` is pre- or post-markup, was not verified; the app should trust `usage.cost` from poll/webhook for the actual charge, and our own preview from `pricing_skus` x duration.

## 2. Direct providers (fallbacks and things OpenRouter lacks)

| Provider | Capability | API shape | Pricing (snapshot) | Notes / terms |
|---|---|---|---|---|
| Google Gemini API | Gemini image (Nano Banana family) | sync `generateContent`, refs as inline parts | Nano Banana 2.1: $0.0336/1K, $0.0504/2K, $0.113/4K; 3.1 Flash Image $0.067-0.151; 3 Pro Image $0.134-0.24; batch half [V ai.google.dev/gemini-api/docs/pricing] | All outputs SynthID-watermarked for video [V]; check image terms [?] |
| Google Gemini API | Video: `gemini-omni-1.1-flash` | Interactions API `interactions.create`; sync unary or `background`; `response_format{type:"video",aspect_ratio,resolution,delivery}`; tasks t2v, i2v, ref2v, edit, extend (+3-10 s per extend, 40 s max) [V docs/omni] | about $0.10/s at 720p [V pricing page] | Multi-turn edit via `previous_interaction_id` (requires `store`); 16:9 and 9:16 only; SynthID. Veo 3.1 Preview retired 2026-10-22 [V] |
| OpenAI | gpt-image-2(.5) | sync `/v1/images/generations` and `/edits` (mask supported) [?: not re-fetched] | [?] | Same models are on OpenRouter; use that |
| OpenAI | Sora | Videos API removed 2026-09-24 [3P] | n/a | Do not build on it |
| Black Forest Labs | FLUX.2 / FLUX 3 image, Kontext edit | async: POST returns `polling_url`, poll [?: docs.bfl.ai pages not retrievable; known pattern from earlier versions] | Kontext pro 4 credits = $0.04, labelled Legacy [3P]; credits $0.01 | OpenRouter has flux.2/flux-3 + `flux-video-edit`; direct only for Kontext/inpaint/fill if needed [?] |
| Runway | Gen-4.5, Aleph(-2), gen4_image | async task, poll task id [?] | credit = $0.01: gen4_turbo 5 cr/s, gen4_aleph 15 cr/s, gen4_image 5-8 cr [V docs.dev.runwayml.com/guides/pricing]; Gen-4.5 12 cr/s and Aleph 2 28 cr/s [3P] | On OpenRouter already |
| Luma | Ray / Dream Machine | async generation id + poll or callback [?] | [?] no reliable rate found | Not on OpenRouter list; skip unless needed |
| Kling (Kuaishou) | Kling 3.0 | async task [?] | $0.08-0.17/s direct, volatile [3P] | On OpenRouter; direct adds nothing |
| Pika | video | [?] not researched; Pika is mostly a consumer app | [?] | Skip |
| MiniMax Hailuo | video | async | see OpenRouter | On OpenRouter |
| ByteDance Seedance / Seedream | video / image | async (BytePlus ModelArk) [?] | token-priced (see 1.2) | Both on OpenRouter |
| Recraft (direct) | V3/V4/V4.1 raster + vector, vectorize, edit | sync REST, OpenAI-style `images/generations` [?] | vector $0.08 (V4/V4.1), $0.30 pro vector 2K, V4 Styles Vector $0.05; V3 vector edit/inpaint/outpaint/bg $0.08; **vectorize $0.01** [V recraft.ai/docs/api-reference/pricing] | Vectorize (raster to SVG) is not on OpenRouter as far as seen: direct-only. Commercial/resale terms not stated on the pricing page [?] |
| Ideogram | gen, remix, edit, reframe, replace-bg | sync REST | $0.03/0.06/0.10 per image (Turbo/Default/Quality) for 4.0, since halved [3P, conflicting] | Best text-in-image; not on OpenRouter list; optional [?] |
| fal.ai | one API for hundreds of models | Queue: `queue.fal.run/<app>`, returns `request_id`; states `IN_QUEUE|IN_PROGRESS|COMPLETED`; status, result, cancel URLs; `fal_webhook` / `webhook_url` (webhook status OK or ERROR; retried, dedupe by request_id) [V fal.ai/docs/model-apis/model-endpoints/queue] | per-output pricing, e.g. Veo 3.1 $0.40/s, Kling 3.0 ~$0.03/s [3P] | Second-source fallback, plus FLUX Kontext, Wan, LoRA etc. Resale/ToS [?] |
| Replicate | many models | `POST /v1/predictions` with `webhook` + `webhook_events_filter`; poll `urls.get` [3P] | pay per second or per output | Per-model licenses vary; open-weights models may restrict commercial use [?] |

## 3. SVG / vector

| Option | Kind | Output | Cost / license | Verdict |
|---|---|---|---|---|
| Recraft V4/V4.1 Vector (+Pro, Styles) | hosted | real SVG, editable paths | $0.05-0.30/img direct [V]; via OpenRouter slugs [V] | **Primary** for illustration-style SVG |
| Recraft Vectorize | hosted | raster to SVG | $0.01 [V] | add as optional "convert to vector" |
| LLM-written SVG (Claude/GPT via our existing `render_svg` tool) | existing | SVG code, good for diagrams/icons/charts | token cost only | **Keep as default for diagrams and figures**; verify by rendering |
| OmniSVG (1.0 3B; 1.1 4B/8B on Qwen2.5-VL) | open weights | text/image to SVG | code+weights Apache-2.0; **MMSVG dataset CC BY-NC-SA 4.0**; 1.1 license not checked [3P/?] | Self-host GPU needed; not worth it now |
| StarVector | open weights | image/text to SVG | Apache-2.0 per a third-party listing; repo looks inactive [3P] | Skip |
| potrace/vtracer (CPU tracers) | open source | raster to SVG, flat art | GPL (potrace) / MIT (vtracer) [?] | Free local fallback for vectorize |

## 4. Open-source design/UI generation and verification

[3P all; searches did not surface specifics, treat as pointers to read the source before adopting]

- abi/screenshot-to-code: MIT; multimodal LLM turns screenshot/mockup/Figma into HTML+Tailwind/React. Its loop is generate then user inspects; no automated visual diff described.
- Open Lovable (Firecrawl): MIT; URL scrape to React app in a sandbox. Needs Firecrawl key.
- Libra: Cloudflare-based v0/Lovable alternative with a screenshot service on Queues.
- OpenUI (wandb) and v0 clones [?]: not retrieved.
- Verification pattern worth copying (design-level, [?] not found documented in these repos): render in headless Chromium/Playwright, take a screenshot, feed it back to a vision model with the prompt and the previous screenshot ("critique, fix"), cap at 2-3 iterations, check console errors. We already have `flutter_inappwebview` for HTML artifacts; on the backend this would need a headless browser, so prefer doing the render-check client-side (screenshot the webview, send as an image part on the follow-up turn).
- Design output for us = existing artifacts (`create_artifact` html, `make_slides`, `render_svg`). New work is the feedback loop, not a new generator.

## 5. How chat products surface async video jobs (patterns to copy)

Based on the OpenRouter/fal/Gemini job models and general product practice [?: no product docs fetched; this is design guidance, not sourced]:

1. Cost preview before submit: show "about $X for N s at 720p" from `pricing_skus`; require confirm above a threshold; 402 preflight when wallet cannot cover the worst case.
2. Job card in the transcript with states queued, generating, ready; elapsed timer plus honest "usually 1-5 min" (no fake percentage; no provider gives progress).
3. Non-blocking: the chat turn ends after submit; the job continues if the app closes; completion triggers an in-app update and an OS notification.
4. Cancel button (fal cancel; OpenRouter has cancelled event) with refund-on-failure semantics (failed means not billed).
5. Result actions: play inline, download, "extend", "edit with prompt", "use as first frame".
6. Persist the final asset ourselves: provider URLs expire (`expires_at`, signed URLs).

## 6. Recommended stack

| Capability | Primary | Fallback |
|---|---|---|
| Image generation | OpenRouter `/images`: `google/gemini-3.1-flash-image` (cheap/fast), `openai/gpt-image-2` or `black-forest-labs/flux-3-image` (quality) | Gemini API direct; fal.ai |
| Image edit / reference | OpenRouter `/images` + `input_references` (gpt-image-2, Gemini image, flux, `krea/k3-edit`) | fal.ai (Kontext), OpenAI `/edits` with mask for true inpainting [?] |
| Mask-based inpainting | gpt-image via OpenAI direct `/edits` [?]; Recraft V3 vector edit | |
| Video t2v / i2v | OpenRouter `/videos`: `google/veo-3.1-fast` (default), `kwaivgi/kling-v3.0-std` (cheap motion), `alibaba/wan-3.0` (budget), `google/veo-3.1` (premium) | fal.ai queue; Gemini Omni Flash direct |
| Video edit | OpenRouter `runway/aleph-2`, `black-forest-labs/flux-video-edit` | Gemini Omni (multi-turn edit) |
| SVG illustration | OpenRouter `recraft/recraft-v4.1-vector` (+ pro) | Recraft direct; LLM-authored SVG |
| SVG diagrams / figures | LLM `render_svg` / `render_diagram` (existing) | |
| Raster to vector | Recraft direct vectorize ($0.01) | vtracer locally |
| Design (UI/slides/HTML) | existing artifacts + screenshot critique loop | |

Resale: OpenRouter is a reseller platform and our current business model already depends on it, so routing through it is the lowest-risk path. Direct-provider and fal/Replicate resale terms, and per-model licenses, were not verified [?]: have the user read each ToS before enabling them.

## 7. Backend and app integration sketch

Backend (backend-exp, Zig/Anole):
1. `images.zig`: switch upstream call to `POST /images`; extend `ImageRequest` with `input_references: []string` (data URLs or https), `n`, `output_format`, `quality`, `resolution`. Return `{mime, data}` as today, plus `images[]` when n>1. SVG: return `mime:"image/svg+xml"` and the decoded text in `data` base64 as now. Charge from response `usage.cost`; when absent, compute from `/images/models/{id}/endpoints` pricing cached by `models.zig`.
2. `models.zig`: second catalog pull for `/images/models` and `/videos/models`; add `kind` (chat|image|video), `max_refs`, `svg`, `pricing_skus` to `/v1/models` entries; apply the x1.15 markup.
3. New `videos.zig`: 
   - `POST /v1/videos {model, prompt, duration, resolution, aspect_ratio, frame_images?, input_references?, generate_audio, session}` returns 202 `{id, status, estimate_micros}`.
   - Preflight: 402 if wallet < worst-case estimate (hold or just check). Insert row in new table `video_jobs(id, user_id, upstream_id, model, status, cost_micros, asset_path, session, created_at, expires_at)` via the migration runner.
   - `GET /v1/videos/:id` (status; refreshes from upstream if pending), `GET /v1/videos/:id/content` (stream from our stored copy), `DELETE` to cancel.
   - Completion: upstream webhook `POST /v1/videos/webhook` (verify HMAC, dedupe on `X-OpenRouter-Idempotency-Key`) with a 30 s poller as fallback for local dev where no public URL exists; download via `unsigned_urls` with the API key; store to disk or object storage; then `billing.charge` once from `usage.cost` (failed = no charge).
4. Chat tools in `tools.zig`/`chat.zig`: extend `generate_image` with `reference_image_ids`/`edit` args (resolve ids to attachments or earlier `image` events); add `generate_video` (server tool that submits and emits `tool_status` + a new SSE `video {id, status}` event, then ends); add `generate_svg` that picks a Recraft vector slug. Keep tool JSON constant to preserve prompt caching.
5. Gateway: no change (images/videos are our own API, not OpenAI-compatible chat).

App (Flutter):
- Composer: image attachments already exist; add "Edit this image" on a generated image (pre-fills references) and a media-mode menu (Image / Video / SVG) that picks `kind` models from the catalog.
- New `features/media/`: `VideoJobCard` (cost preview dialog, states, elapsed timer, cancel, play via `video_player`/media_kit, save, extend), job polling by id (survive restart: persist job ids in message parts, resume polling on open), OS notification on completion.
- Image viewer: zoom, save, "edit", SVG rendered with existing `svg_view`, with download of the .svg.
- Billing UI: show estimated and actual cost per job in the usage meter.

## 8. Open questions / unverified

- OpenRouter per-model image pricing rows (`/images/models/{m}/endpoints`) and whether video `pricing_skus` includes OpenRouter's fee.
- Whether `/images` supports a mask; no mask field is documented.
- Official OpenAI Sora shutdown page (only third-party reports read); OpenAI image API shapes not re-fetched.
- BFL, Luma, Kling-direct, Pika, Ideogram-direct, Replicate API specifics and all direct-provider resale terms.
- Real figures for polling latency per model (docs only say 30 s to several minutes).
- OmniSVG 1.1 license.

## Sources

- https://openrouter.ai/docs/features/multimodal/image-generation (fetched 2026-10-30)
- https://openrouter.ai/api/v1/images/models (fetched 2026-10-30)
- https://openrouter.ai/docs/features/multimodal/video-generation (2026-10-30)
- https://openrouter.ai/api/v1/videos/models (2026-10-30)
- https://ai.google.dev/gemini-api/docs/video and /docs/omni and /docs/pricing (2026-10-30)
- https://www.recraft.ai/docs/api-reference/pricing (2026-10-30)
- https://fal.ai/docs/model-apis/model-endpoints/queue (2026-10-30)
- https://docs.dev.runwayml.com/guides/pricing (via search snippet, 2026-10-30)
- https://docs.bfl.ai/ (landing only, 2026-10-30)
- Sora shutdown: https://the-decoder.com/openai-sets-two-stage-sora-shutdown-with-app-closing-april-2026-and-api-following-in-september/ , https://help.make.com/openai-sora-and-video-modules-deprecation-by-september-24-2026 [3P]
- Pricing comparisons [3P]: https://costbench.com/software/ai-media-apis/runway-api/ , https://developer.puter.com/tutorials/flux-api-pricing/ , https://developer.puter.com/tutorials/ideogram-api-pricing/ , https://devtk.ai/en/blog/ai-video-generation-pricing-2026/
- OmniSVG: https://huggingface.co/OmniSVG/OmniSVG ; StarVector: https://www.sourcepulse.org/projects/1941692
- screenshot-to-code: https://repopilot.app/r/abi/screenshot-to-code ; Open Lovable: https://openapps.pro/apps/open-lovable ; Libra: https://github.com/jinwyp/libra
