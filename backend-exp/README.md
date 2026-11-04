# backend-exp

The experimental EveryAI backend, written in Zig 0.17 on
[Anole](https://github.com/xuckless/anole). It replaces `backend/` (FastAPI)
with a `/v1` API: auth, an SSE chat gateway with a server-side tool loop, an
OpenAI-compatible LLM gateway for coding agents (OpenHands), the model shop,
image generation, and usage billing (plans + prepaid wallet, upstream cost × 1.15).
All model traffic goes through OpenRouter.

```
cp .env.example .env    # then set OPENROUTER_API_KEY here or in the repo-root .env
zig build run           # http://localhost:8080, API docs at /docs
zig build test          # unit tests + routes in memory against a fake OpenRouter
```

Anole is a path dependency (`../../../PersonalProjects/anole` in
`build.zig.zon`) while both are developed together.

| Area | Endpoints | Source |
| --- | --- | --- |
| Auth | `POST /v1/auth/signup\|login\|google\|refresh\|logout`, `DELETE /v1/auth/account`, `GET /v1/me` | `auth.zig` |
| Gateway keys | `POST/GET /v1/keys`, `DELETE /v1/keys/:id` (`sk-eai-…`) | `auth.zig` |
| Models | `GET /v1/models` (OpenRouter catalog, hourly, marked-up prices), `GET /v1/models/defaults` | `models.zig` |
| Chat | `POST /v1/chat/stream` (SSE), `POST /v1/chat/tool_result` | `chat.zig`, `tools.zig`, `tool_wait.zig` |
| Gateway | `POST /v1/chat/completions` (OpenAI-compatible, streaming) | `gateway.zig` |
| Images | `POST /v1/images` `{prompt, model?, engine?: raster\|vector, n?, quality?, output_format?, input_references?}` returns `{mime, data, images}` (OpenRouter `/images`) | `images.zig` |
| Figure polish | `POST /v1/figures/polish` `{svg, png_base64, brief?, session?}`: a vision model (`AUX_POLISH_MODEL`, Haiku 5.5) looks at the render, lists defects and revises the SVG once; the revision must pass the `render_svg` checks. Returns `{svg, defects, changed, kept_original, model, charged_micros}`; 402 preflight, capped by `POLISH_MAX_MICROS` (50000) | `polish.zig` |
| Decide | `POST /v1/aux/decide` `{job?, text, instructions?, questions: [{id, kind: bool\|choice\|score, prompt, choices?}]}` (1-64 questions, 2-64 choices, text up to 200K characters, else 413): a cheap model (`AUX_DECIDE_MODEL`, else the utility model) answers under a strict JSON schema. Returns `{answers: [{id, value}], model, charged_micros}`; `value` is a bool, one of the choices, a number 0-1, or `"unsure"` (also for anything the model got wrong). JWT or `sk-eai-` key, metered as kind `decide` under `X-EveryAI-Session`; 402 preflight, 502 when the upstream fails | `decide.zig` |
| Billing | `GET /v1/plans`, `GET /v1/billing`, `GET /v1/usage`, `POST /v1/billing/checkout`, `POST /v1/billing/webhook` | `billing.zig` |
| Remote hosts | `POST/GET /v1/remote/hosts`, `DELETE /v1/remote/hosts/:id`, `DELETE /v1/remote/devices/:id`, `POST /v1/remote/pair`, `POST /v1/remote/pair/redeem`, `GET /v1/remote/pair/:id`, `POST /v1/remote/pair/:id/approve\|deny`; WebSockets `/v1/remote/host` and `/v1/remote/client/:host_id` relay end-to-end encrypted frames (contract in the `remote.zig` header) | `remote.zig` |

## Chat stream

Request: `{model?, mode: chat|search|research, messages: [{role, content}], tools_enabled?, session?, client_tools?, images?: [{id, url?}], memory?}`.
`model: "everyai/auto"` (listed first in `/v1/models` as "EveryAI · Auto") lets the decider
(`auto.zig`) read the newest message and up to two earlier turns and pick the mode (only when
`mode` is `chat`), rich answers (`tools_enabled`; never turned on when the request turned it off)
and a tier: `AUTO_FAST_MODEL` / `AUTO_BALANCED_MODEL` / `AUTO_BEST_MODEL` (Claude Haiku / Sonnet /
Opus 5.5). "Unsure" keeps the request's values on the balanced tier. The stream then starts with
`route {model, mode, tools_enabled}` (what the turn runs on) and the decider's `usage {kind:
"decide"}`; Research picked by Auto runs at Quick depth unless `research_depth` was sent.
`images` lists the conversation's images (`img_<n>` generated, `upload_<n>` attached) so
`generate_image` can edit them (`edit_of`) or follow them (`references`); new ids continue from the highest `img_<n>`.

Events: `route {model, mode, tools_enabled}` (Auto only, first), `delta {text}`, `reasoning {text}`, `sources {sources}` (new sources,
appended in citation order), `tool {id, name, arguments}` (a UI tool for the
app to render), `tool_wait {id, name, arguments}` (a client-executed tool the
turn waits on), `tool_status {id, name, status, detail?}` (a server tool),
`image {id, image_id, mime, data, prompt, revises?}` (`revises`: the image it is a new version of;
vector images are `image/svg+xml`), `usage {model, prompt_tokens, completion_tokens,
cached_tokens, cache_write_tokens, charged_micros}` (one per upstream call),
`followups {questions}`, `done {}`, `error {message, retryable, status?}`.

- Search mode adds OpenRouter's web plugin (`SEARCH_ENGINE`, default `exa`,
  which always returns citations). Research mode switches to `RESEARCH_MODEL`.
- UI tools (artifacts, SVG, Mermaid, charts, quizzes, flashcards, slides) are
  sent to the app and acknowledged to the model; `web_fetch`, `web_search`,
  `summarise_parts` and `generate_image` run on the server. At most `MAX_TOOL_STEPS` model calls a turn.
- `summarise_parts {url, question}` answers a question from a source too long to
  read whole (`summarise.zig`): the text is cut into ~12K-character parts on
  paragraph boundaries, the decider scores each part (one `decide` call per 32),
  the 12 best plus the unsure ones are summarised in parallel on
  `AUX_SUMMARISE_MODEL` (else the utility model; 6 at a time), and one merge
  call answers with `[part N]` references. One or two parts come back whole.
  Progress is `tool_status {id, name: "summarise_parts", status: "running",
  detail: "part 14 of 40"}`; usage kinds `decide` and `summarise`; the source
  joins the turn's citation numbers.
- Client-executed tools: UI tools named in `client_tools` come as `tool_wait`,
  and the turn waits for `POST /v1/chat/tool_result {call_id, result, is_error?}`
  (404 when nothing waits for that call). The model gets the app's result, or
  `Error (timeout): …` after `CLIENT_TOOL_TIMEOUT_MS` (default 300 s). A
  `tool_status` (done, or failed with detail `timed out`) closes each wait; SSE
  comments keep the stream alive every 15 s.
- Memory: `memory` (a string, at most 16 KiB) is the user's saved notes as the
  app froze them when the chat began. It goes in as a second system message
  right after the constant system prompt, so the cached prefix holds. The
  `memory` and `search_chats` tools run only in the app (notes and chat history
  stay on the device); when the app does not list them in `client_tools`, the
  model gets an error saying they are off.

## Prompt caching

- The system prompt and tool schemas are compile-time constants (`tools.zig`),
  so every request starts with the same bytes.
- Anthropic and Gemini models get `cache_control` breakpoints on the system
  prompt and the latest message (`CACHE_TTL`, 5m). Gateway requests without
  breakpoints get them on the last tool, the system message and the latest
  message (`GATEWAY_CACHE_TTL`, 1h).
- Other providers cache stable prefixes on their own.

Cached and cache-write tokens are recorded per call in `usage_events`.

## Billing

- Amounts are integer micro-dollars; the charge is `ceil(cost × MARKUP)`.
- A charge is debited from the plan's monthly included usage first, then from the wallet.
- Zero-cost models are never debited and work on every plan.
- A paid call with nothing left answers 402 `out_of_credits` before reaching
  the upstream.
- Without `STRIPE_SECRET_KEY`, checkout is mocked: it credits or switches the
  plan immediately.
- With `DEV_AUTH=true`, credential-less requests act as a seeded `dev-user`
  (pro plan, $20 wallet).

## Deployment

The dev server (0.1.0-dev-nonsigned, BYOK only, no sign-in) runs on a GCP VM with Anole's own TLS and a global
per-address rate limit: see [`deploy/README.md`](deploy/README.md). `TLS_CERT_PATH`/`TLS_KEY_PATH` switch the listener
to HTTPS; `RATE_LIMIT_PER_MINUTE` (600, 0 = off) limits every route per client address.

## Anole pieces

Outbound SSE parsing uses `anole.sse.Parser` and migrations use
`anole.db.migrate` (Anole 0.5.1). The migration list lives in
`src/migrations.zig`; the SQL files are in `src/migrations/`.
