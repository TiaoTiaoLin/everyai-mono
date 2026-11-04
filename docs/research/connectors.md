# Connectors and Claude-grade vector art: research

Date: 2026-10-30. Scope: how Claude/ChatGPT connectors work, what to copy, how to build connectors in EveryAI, and how to get Claude-quality SVG output. The MCP spec, security checklist and roadmap M1-M6 are already in `docs/research/mcp.md`; the resvg/renderer notes are in `docs/research/media/renderers-and-mcp.md`. This doc does not repeat them.

## 1. Sources

Clones (shallow, in `/private/tmp/claude-501/connectors-vector-research/<name>`; temp, may be gone):

| Repo | Commit | License (checked by reading LICENSE) |
|---|---|---|
| github-mcp-server | f2a07cd | MIT |
| google_workspace_mcp | c0bff66 | MIT |
| notion-mcp-server | cf16e5c | MIT (Notion Labs 2025) |
| modelcontextprotocol/servers | 194cc86 | Transition MIT to Apache-2.0; docs CC-BY-4.0 |
| arcade-mcp | f8099ad | MIT |
| composio | a81ccf0 | MIT (Sampark Inc 2025) |
| activepieces | f072e2c | MIT Expat except `packages/ee/` and `packages/server/api/src/app/ee` (commercial) |
| nango | 17093d4 | Elastic License 2.0 (no managed-service use) |
| starvector, OmniSVG | 0e083c1, 308b49b | Apache-2.0 (per scout) |
| Chat2SVG | 9e60953 | No LICENSE file |
| SVGDreamer, VectorFusion-pytorch | 43a2813, 2f1323c | MIT |
| vtracer | e71343f | MIT-style grant (SPDX name not stated) |
| resvg | e1a4c92 | Apache-2.0 or MIT (both files present) |
| svgo | 7b0c686 | MIT |

Docs: support.claude.com custom connectors (11175166) and directory FAQ (11596036); platform.claude.com MCP connector; developers.openai.com/apps-sdk (redirects to a Plugins index). Papers: arXiv 2603.16189 (CTRL-S), 2603.29852 (VectorGym), 2509.05208 (SGP-GenBench), 2411.16602 (Chat2SVG). All doc and paper claims come from fetch/search summaries, not full reads (see section 11).

## 2. Executive summary: top 10 actions

| # | Action | Impact | Effort |
|---|---|---|---|
| 1 | Server-side render check for `render_svg` (resvg CLI), return the error to the model for one retry | High | Small |
| 2 | SVG craft section (plan, palette, layers, viewBox) in the `render_svg` tool description or an appended prompt block; write original text | High | Small |
| 3 | Code: pass user-configured MCP servers via OpenHands `mcp_config` (mcp.md M1) | High | Small |
| 4 | Encrypted per-user token vault (AEAD, key id, rotating refresh) plus migration and SSRF-safe fetcher | High | Medium |
| 5 | Backend MCP client over Streamable HTTP, connector tools appended after the constant tool list | High | Large |
| 6 | Backend-owned OAuth 2.1 + PKCE flow, one fixed HTTPS callback, app polls status | High | Medium |
| 7 | Per-tool approval and per-conversation toggles; write tools gated | High | Medium |
| 8 | Prompt-injection hardening of connector output (untrusted wrapper, block markdown image exfiltration) | High | Small |
| 9 | Opt-in render-and-critique "Polish" loop (rasterize, vision model, 1-2 rounds) | Medium | Medium |
| 10 | Small local SVG benchmark (30-50 prompts, render success then VLM judge) | Medium | Medium |

Deferred: Anthropic `mcp_servers` passthrough (stopgap only), vtracer path, self-hosted StarVector/OmniSVG, embedding Nango/Activepieces/Composio.

## 3. How Claude and ChatGPT connectors work

Claude (per support.claude.com, summary-level):
- A custom connector is a remote MCP server over HTTPS, reached from Anthropic's cloud. Private networks, VPNs and firewalls block it.
- Sign-in modes: "Sign in now", "Sign in when needed", "No sign in".
- OAuth client identity: Claude's published identity (recommended), automatic registration, or your own client. Static API keys/bearer tokens can be sent as headers; stored credentials are encrypted.
- Users toggle connectors and individual tools per conversation. Free plan: one custom connector.
- Directory: Anthropic-reviewed servers; OAuth 2.0 only if user auth is needed; pure client-credentials flows are not supported.

User-facing flow: Settings, Connectors, add from the directory or by URL, sign in (browser OAuth), then in a chat enable the connector (and optionally disable single tools); the model calls tools, and the UI shows tool steps.

Claude API (platform.claude.com MCP connector, beta): request carries `mcp_servers:[{type:"url", url, name, authorization_token}]` plus `tools:[{type:"mcp_toolset", mcp_server_name}]` under a beta header (`mcp-client-2026-09-15` or `mcp-client-2025-11-20`). Server must be public, Streamable HTTP or SSE; STDIO is unsupported. The caller supplies the OAuth token. Works only on the Anthropic upstream.

ChatGPT: the fetched page redirected to a "Plugins" index: a plugin is skills plus an MCP server plus optional UI, and tools can return UI resources. Same shape as Claude (MCP + OAuth) with richer in-chat UI. EveryAI already has tool-returned UI (`render_*`, `make_*`), so MCP-Apps-style UI resources can wait. Product naming (Apps SDK vs Plugins) is unconfirmed.

## 4. Reuse catalogue

Verdicts: copy (take code/ideas freely), host (run it as a sidecar/service), call (use the vendor's hosted endpoint), avoid.

| Connector / platform | License | Hosting | Auth | Quality | Cost | Verdict |
|---|---|---|---|---|---|---|
| github-mcp-server | MIT | Go binary (stdio) or GitHub-hosted remote | PAT or OAuth | High, GitHub-maintained, toolsets + `__toolsnaps__` | Free | Call hosted for chat; host binary via `mcp_config` in Code; copy toolset and snapshot-test ideas |
| google_workspace_mcp | MIT | Self-hosted Python | OAuth 2.1 + PKCE, per-user credential store | Broad (Gmail, Drive, Calendar, Docs, Sheets, Slides, Forms, Tasks, Chat) | Free; Google app verification needed for restricted scopes before public use | Host as sidecar or reference; copy `auth/` design |
| notion-mcp-server | MIT | Local server; Notion also hosts a remote MCP | Token or OAuth (hosted) | Official | Free | Call hosted remote; repo as schema reference |
| modelcontextprotocol/servers | MIT to Apache-2.0 | Local | n/a | Reference quality | Free | Copy conventions only; fetch/filesystem overlap existing tools |
| arcade-mcp | MIT | Self-host lib; paid hosted platform | Tool-declared OAuth scopes | Good design, evals | Hosted pricing unchecked | Copy the declare-scopes model and evals layout |
| Composio | MIT (repo) | Hosted platform | Hosted auth | Broad, not explored | Resale terms unchecked | Avoid embedding; optional user-added MCP URL later |
| Activepieces pieces | MIT Expat outside ee/; pieces may carry own terms | TypeScript, not MCP | Per piece | 744 community pieces | Free | Mine as integration list and API recipes only; never copy ee/ |
| Nango | ELv2 | Self-host or hosted | Large provider catalog | Strong architecture | n/a | Avoid copying; read for keystore/kms/provider-catalog design only |
| Pipedream, Slack, Linear, Atlassian MCP | not read | Vendor hosted | Unknown | Unknown | Unknown | Check before committing (section 11) |

## 5. EveryAI architecture

```
 Flutter app (6 platforms)
   Connectors settings, per-chat toggles, approval cards
   url_launcher opens system browser for OAuth; polls GET /v1/connectors/:id
        |
        v   /v1/chat/stream (+ enabled connector ids)
 backend-exp (Zig)
   chat.zig tool loop: constant tools first, connector tools appended last
   mcp_client.zig  --(Streamable HTTP, bearer from vault)-->  remote MCP servers
   connectors.zig: catalog, OAuth 2.1 + PKCE (CIMD client id), callback
                   /v1/connectors/oauth/callback, SSRF-safe fetch, rate limits
   token vault: AEAD (key from env, key id column), per (user, issuer, resource),
                store rotated refresh token each time (like auth.zig)
        |
        +--> usage_events (connector-induced tokens already metered)

 Code sessions: app -> OpenHands sidecar `mcp_config` (stdio + remote), same catalog
 Consent UI: connect -> scopes shown -> per-tool allow/ask/block -> writes ask
```

Key design points:
- Runtime option A (Anthropic `mcp_servers` passthrough) is cheap in `anthropic.zig` but Anthropic-route only, bypasses the tool loop and approvals. Use only as a stopgap.
- Runtime option B (own MCP client) is provider-neutral and keeps cost accounting. Chosen design.
- Prompt cache: system prompt and tool JSON in `tools.zig` stay constant. Append connector tools last; a per-conversation toggle changes the tool list and costs one cache miss. Group tools into toolsets (github-mcp-server idea) to keep the list small.
- Backend owns OAuth, so `flutter_appauth` (Android/iOS/macOS only, per a pub.dev summary) is not needed. `url_launcher` and `flutter_secure_storage` are already dependencies; add `app_links` later for an `everyai://` refocus.
- The catalog classifies tools as read/write itself (Arcade model), not trusting server annotations.
- No AEAD exists in `util.zig` today (only sha256); needs new code with `std.crypto` (API for 0.17 not compiled).

## 6. First five connectors to ship, with steps

1. GitHub: use the hosted remote MCP with OAuth (or PAT as the first bearer-token version); in Code, run the `github-mcp-server` binary through `mcp_config`. Steps: catalog entry, vault, client, read toolsets only, then writes with approval.
2. Google Workspace (Drive, Gmail, Calendar): self-host `google_workspace_mcp` or use Google's endpoints if available; needs own Google OAuth client and app verification for restricted scopes. Start with Drive and Calendar read.
3. Notion: hosted remote MCP with OAuth.
4. Linear: vendor remote MCP, availability and client-registration rules unverified.
5. Slack: vendor remote MCP, same caveat.

Order of work per connector: catalog JSON (`name, mcp_url, auth mode, scopes, tool classes`), OAuth flow, tool list fetch, read-only enable, approval UI for writes, eval with a handful of scripted tasks.

## 7. Vector art: state of the art and what to copy

Papers (from search results, not read): CTRL-S (chain-of-thought SVG, GRPO, DINO similarity reward), VectorGym (benchmark and RL), SGP-GenBench (render validity first, then fidelity and compositionality), IntroSVG (generator-critic with render feedback). Takeaway: renderability gating and render feedback are the strongest levers.

Open tools: Chat2SVG stages are `1_template_generation`, `2_detail_enhancement`, `3_svg_optimization` with `prompts.yaml`/`prompts_edit.yaml`; its README says Anthropic APIs are supported. Stages 2-3 need PyTorch/diffvg/GPU and there is no LICENSE, so take the technique (plan, template, refine), not text or code. resvg (render and validate), svgo (normalize/minify, needs Node), vtracer (raster to vector for /v1/images output). StarVector, OmniSVG (Apache-2.0, GPU), SVGDreamer, VectorFusion (MIT, slow optimization) are not a first step.

Proposed pipeline on top of existing `render_svg` and the `svg_view` sanitizer:
1. Prompt: SVG craft block (composition, palette, layers, viewBox, gradients, grouping); original wording.
2. Generate with the strongest chat model.
3. Validate with resvg CLI from Zig (sidecar-style subprocess); on failure return the error as a tool result for one retry.
4. Optional Polish: rasterize, vision-model critique, 1-2 revisions; record extra calls in `usage_events`.
5. Finalize: minify (svgo needs Node, so begin with the app sanitizer) then sanitizer.
6. Optional: `/v1/images` + vtracer for illustration styles, marked as traced.
7. Evaluate with a local benchmark modeled on VectorGym/SGP-GenBench prompt types.

## 8. Security checklist (additions to mcp.md section 8)

- Tokens: AEAD-encrypted, key id for rotation, never sent to the model, never logged; save rotated refresh tokens.
- OAuth: PKCE S256, `resource` param, `iss` check, state to verifier map with short TTL, fixed HTTPS redirect, SSRF-safe metadata fetch (also fixes `web_fetch`).
- Treat tool results as untrusted: delimited wrapper plus a constant system-prompt line; cap size; strip or block markdown image/link auto-fetch from connector output in `chat_markdown.dart`.
- After untrusted connector content enters a turn, require approval for write/destructive tools and cross-connector calls.
- EveryAI-owned read/write classification; per-tool toggles; rate limits per user/server; log every call.
- Code: connector consent shown before `mcp_config` is passed; stdio servers run with the sidecar's permissions, so list them explicitly.
- Licensing: no Nango code, no Activepieces `ee/`, no verbatim Chat2SVG prompts.

## 9. Roadmap

1. Week 1: SVG render check and craft prompt (items 1-2); Code `mcp_config` Settings list (M1).
2. Weeks 2-3: vault, migration, SSRF-safe fetcher; bearer-token connector (GitHub PAT) through the MCP client.
3. Weeks 3-5: OAuth 2.1 flow, catalog and settings UI, approvals, injection hardening.
4. Weeks 5-6: Google Workspace, Notion, Linear, Slack; SVG Polish loop and benchmark.
5. Later: connector UI resources, vtracer path, self-hosted SVG models only if the loop plateaus.

## 10. Spot-check results

Verified against the clones before writing: Activepieces LICENSE has the `ee/` carve-out and MIT Expat for the rest; SVGDreamer and VectorFusion are MIT (the scout's first report left them unread); Nango is ELv2; notion-mcp-server is MIT (Notion Labs); servers repo states an MIT to Apache-2.0 transition; vtracer header is an MIT-style grant; Chat2SVG has no LICENSE file and its README line 14 says the Anthropic API is supported; `google_workspace_mcp/auth/oauth_config.py` sets `pkce_required` from the OAuth 2.1 flag and allows only S256 then. Corrected claim: Activepieces is not simply "MIT"; it is MIT outside `ee/`. `docs/research/mcp.md` and `media/renderers-and-mcp.md` exist and mention `mcp_config` and resvg.

## 11. Unverified

- Connector doc facts are from fetch summaries; the directory FAQ was seen only in Korean; Claude's OAuth callback URLs, the allowlist/denylist and tools-versus-resources behavior were not read.
- ChatGPT Authentication, UI reference and review pages were not opened.
- Linear, Slack, Atlassian, Pipedream hosted MCP availability and client-registration rules; Google hosted endpoints; Composio/Arcade/Pipedream/Nango resale terms.
- OpenHands 1.59.0 `mcp_config` schema and remote HTTP support were not tested; Anole HTTP client POST+SSE for MCP untested.
- Zig 0.17 `std.crypto` AEAD API not compiled; Nango cipher details inferred from a file head.
- Papers' claims come from search results; arXiv ids not checked against the papers. LLM4SVG not located.
- Chat2SVG stage behavior inferred from README and directory names; `prompts.yaml` unread.
- Cache cost of appending connector tools and resvg subprocess overhead are estimates.
- StarVector/OmniSVG Apache-2.0 and resvg dual license are per the scout/inferred from file names.
