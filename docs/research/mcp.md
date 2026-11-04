# Model Context Protocol (MCP): research for EveryAI

Researched 2026-10-30. Spec revision studied: **2026-07-28** (latest; `schema/2026-07-28/schema.ts` sets
`LATEST_PROTOCOL_VERSION = "2026-07-28"`). Earlier revisions: 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05, plus `draft`.
Citation paths are relative to `/private/tmp/claude-501/mcp-skills-research/` (clone names in the table below).

## 1. Sources

| Source | Clone | Commit | License |
|---|---|---|---|
| MCP spec and docs, modelcontextprotocol/modelcontextprotocol (site modelcontextprotocol.io) | `mcp-spec` | 84d8457 (2026-10-29) | Moving MIT to Apache-2.0 (new code/spec), docs CC-BY-4.0, older contributions MIT |
| MCP Apps, modelcontextprotocol/ext-apps | `mcp-ext-apps` | cf599cc | same MCP license |
| MCP registry | `mcp-registry` | 72042e5 | same |
| MCP inspector | `mcp-inspector` | e321738 | same |
| TypeScript SDK | `mcp-ts-sdk` | 39ae8e6 | same |
| Python SDK | `mcp-py-sdk` | d7845c0 | MIT (Anthropic, PBC) |

Not cloned: modelcontextprotocol/ext-skills (Skills-over-MCP, SEP-2640) and the Tasks extension repo. Claude API MCP connector
docs (platform.claude.com) were consulted by the scout only for limitations. See `docs/research/skills.md` for Skills.

Spot-checked while writing (all matched): `LATEST_PROTOCOL_VERSION` (schema.ts:30); "MUST NOT rely on prior requests"
(basic/index.mdx:191); "MUST treat a client disconnect as cancellation" (patterns/cancellation.mdx:40); stdio "SHOULD NOT follow"
the OAuth spec (authorization/index.mdx:21); PKCE "MUST refuse to proceed" (security-considerations.mdx:57); MRTR "MUST send
server-to-client requests" (patterns/mrtr.mdx:10); tool annotations untrusted (server/tools.mdx:306); Sampling deprecated
(client/sampling.mdx:8); registry "not intended to be directly consumed" (docs/registry/about.mdx:66); MCP Apps mime type
`text/html;profile=mcp-app` (ext-apps specification/draft/apps.mdx:49); SDK tiers (docs/docs/2026-07-28/sdk.mdx).
One scout citation was wrong: it cited `basic/index.mdx:27-125,185-201` for the stateless rule, which is at line 191; the
pattern pages live under `basic/patterns/`, not `basic/`.

## 2. Executive summary: top 10 for EveryAI

| # | Item | Impact | Effort |
|---|---|---|---|
| 1 | Code: user-configured MCP servers via OpenHands `mcp_config` (Settings list, per project/global) | High | Small |
| 2 | Code: consent dialog for stdio servers (untruncated command, dangerous-pattern flag); MCP tools count as non-read-only in AgentMode | High | Medium |
| 3 | Chat: MCP client in backend-exp, remote Streamable HTTP only, bearer tokens first | High | Large |
| 4 | Chat: host-side per-tool approval and visible tool list (spec: human in the loop, annotations untrusted) | High | Medium |
| 5 | SSRF-safe fetcher shared by `web_fetch` and the MCP client (exposure exists today) | High | Small |
| 6 | Render MCP result content (image, audio, resource_link, structuredContent) in transcripts | High | Medium |
| 7 | Map elicitation (MRTR `input_required`) onto the existing question card | Medium | Medium |
| 8 | Stop/cancel propagation: closing the upstream stream is the cancel | Medium | Small |
| 9 | MCP Apps host (reuse `web_view.dart`, small AppBridge) | Medium | Large |
| 10 | Expose EveryAI tools as an MCP server (`/mcp`, sk-eai- keys) | Low | Medium |

Skip: Sampling (deprecated, and would bypass the billing meter), Roots, Tasks (defer), consuming the official registry directly.

## 3. Protocol overview (2026-07-28)

The revision is a **stateless redesign**. Removed: the `initialize` handshake, `Mcp-Session-Id`, `ping`, `logging/setLevel`,
`notifications/roots/list_changed`, SSE resumability (`Last-Event-ID`). Each request carries `_meta`
`io.modelcontextprotocol/protocolVersion` and `.../clientCapabilities` (required) and `.../clientInfo` (SHOULD). Servers MUST
implement `server/discover`. JSON-RPC 2.0, every result has `resultType` (`complete` or `input_required`; absent means complete
from older servers). Error codes -32020..-32099 are reserved for MCP: HeaderMismatch -32020, MissingRequiredClientCapability
-32021, UnsupportedProtocolVersion -32022 (`data: {supported, requested}`). Resource-not-found is now -32602.

Message-flow sketch (Streamable HTTP):

```
client                                         server
  | POST /mcp  server/discover  (_meta: version, caps)    |
  |------------------------------------------------------>|
  |<-- 200 JSON {supportedVersions, capabilities, ttlMs} --|
  | POST /mcp  tools/call  headers: MCP-Protocol-Version,  |
  |            Mcp-Method, Mcp-Name                        |
  |------------------------------------------------------>|
  |<-- SSE: notifications/progress ... final response -----|   (closing stream = cancel)
  |  or result {resultType:"input_required",               |
  |             inputRequests:{...}, requestState}         |   (MRTR)
  | POST /mcp  tools/call again + inputResponses,          |
  |            requestState                                |
  |------------------------------------------------------>|
  | POST /mcp  subscriptions/listen (long-lived)           |   (list_changed, resource updates)
```

Key mechanisms:

- **Transports.** stdio: newline-delimited JSON on stdin/stdout, stderr is free-form logging (not an error); shutdown by closing
  stdin, then SIGTERM/SIGKILL. Streamable HTTP: one endpoint, every client message a fresh POST with `Accept: application/json,
  text/event-stream`; notifications get 202; a request gets one JSON response or an SSE stream scoped to that request; the server
  MUST NOT send independent requests on it. Validate `Origin` (403), bind localhost when local. HTTP+SSE (2024-11-05) is
  deprecated. (transports/stdio.mdx, transports/streamable-http.mdx)
- **Versioning.** No negotiation: each request accepted or rejected independently. "Modern" = 2026-07-28+, "legacy" = 2025-11-25
  and earlier with `initialize`; dual-era clients fall back (streamable-http.mdx:650-705, stdio.mdx:111-154).
- **MRTR** replaces server-initiated requests (sampling, elicitation, roots) with `input_required` results that the client
  answers by retrying the original request with `inputResponses` and `requestState`. No sticky sessions or shared storage needed.
- **Cancellation/progress.** HTTP: disconnect is the cancel; stdio: `notifications/cancelled`. Progress via `progressToken` in
  `_meta`, strictly increasing `progress`. Always enforce a maximum timeout.
- **Subscriptions.** `subscriptions/listen` is one POST stream carrying list_changed and resource updates, tagged with
  `io.modelcontextprotocol/subscriptionId`.
- **Caching.** `tools/list`, `prompts/list`, `resources/list|read|templates/list` and `server/discover` carry `ttlMs` and
  `cacheScope`; `tools/list` SHOULD be deterministic (helps prompt-cache hits, which matches EveryAI's cache rules).
- **Deprecated** (12-month minimum window): Logging, Sampling, Roots. Tasks moved to extension `io.modelcontextprotocol/tasks`
  (poll `tasks/get`, `tasks/update`).

## 4. Server and client features

- **Tools**: `inputSchema`, optional `outputSchema` (JSON Schema 2020-12), annotations (`readOnlyHint`, `destructiveHint`,
  `idempotentHint`, `openWorldHint`), which clients MUST treat as untrusted unless from a trusted server. Results: `content` of
  text, image (base64), audio, `resource_link`, embedded resource; optional `structuredContent` (SHOULD also be serialized into a
  text block). (server/tools.mdx)
- **Resources**: list/read/templates, text or blob contents, annotations, subscriptions via listen. **Prompts**: user-controlled
  templates (slash-command style). **Completion**: `completion/complete` for prompt and template arguments.
- **Elicitation** (client): form mode (flat schema, accept/decline/cancel) and URL mode for out-of-band flows. Servers MUST NOT
  request passwords, keys or payment credentials in form mode. URL mode: no prefetch, explicit consent, show full URL.
- **Sampling** (deprecated), **Roots** (deprecated): do not implement.
- **Tasks** extension: durable handle for long operations (working, input_required, completed, failed, cancelled).
- **Extensions** negotiated through the capabilities `extensions` map (`io.modelcontextprotocol/ui`, `.../tasks`, Skills).

## 5. Authorization and security

- HTTP transports SHOULD follow the OAuth 2.1-based spec; stdio SHOULD NOT and takes credentials from the environment.
- MCP server is an OAuth resource server publishing Protected Resource Metadata (RFC 9728). Clients read `WWW-Authenticate
  resource_metadata` on 401, then AS metadata via RFC 8414 or OIDC discovery; the metadata `issuer` must equal the issuer used
  to build the URL.
- Registration priority: pre-registered, Client ID Metadata Documents (HTTPS URL client_id), DCR (deprecated), prompt the user.
- PKCE S256 mandatory (refuse if `code_challenge_methods_supported` absent). RFC 8707 `resource` parameter MUST be sent in
  authorize and token requests. Validate `iss` on the callback (RFC 9207) before using the code. Bearer in the header only.
- Servers validate token audience; **token passthrough is forbidden**. Scope step-up through 403 `insufficient_scope`.
- State-handle hijacking replaces session hijacking: never treat a handle as authentication; bind to the verified user ID.
- Clients running server-side MUST defend against SSRF when fetching metadata. One-click local server install MUST show the exact
  command untruncated, flag it as code execution, require explicit approval.
- Tool results from one server are untrusted input to another. The spec has no dedicated tool-poisoning section; any injection
  policy is EveryAI's own.
- Auth extensions: client_credentials and enterprise-managed authorization (docs/extensions/auth/).

## 6. Ecosystem

- **SDKs**: Tier 1 TypeScript, Python, C#, Go, Rust, Ruby; Tier 2 Java; Tier 3 Swift, PHP, Kotlin. No Dart, Zig or C SDK in the
  official list; a hand-written client is needed. Whether the SDKs already implement the stateless era was not checked.
- **MCP Apps** (`io.modelcontextprotocol/ui`): tool `_meta.ui.resourceUri` points to a `ui://` resource, mime
  `text/html;profile=mcp-app`, rendered in a sandboxed iframe with a JSON-RPC-over-postMessage bridge (View `App`, Host
  `AppBridge`). Flow: `ui/initialize`, then `ui/notifications/initialized` (host must not send earlier), then `tool-input` and
  `tool-result` (with UI-only `structuredContent`); the view can call `tools/call`, `ui/message`, `ui/open-link`,
  `ui/download-file`, `ui/request-display-mode`. CSP declared in `_meta.ui.csp`; default is `default-src 'none'` with
  `connect-src 'none'`. Tool `visibility` is model, app, or both. Claude web and Desktop host Apps; Claude Code does not.
- **Registry**: preview metadata catalog (`server.json`, reverse-DNS names, npm/PyPI/remote entries). Explicitly not for direct
  host consumption; use downstream aggregators with the same OpenAPI shape.
- **Inspector**: `@modelcontextprotocol/inspector` (web, CLI, TUI, experimental `mcpdo`), Node 22.19+. A test tool, not embeddable.
- **Claude API MCP connector**: beta `mcp_servers` + `mcp_toolset`, tools only, public HTTP only, caller handles OAuth.
- **Governance**: SEP process with working groups.

## 7. MCP in EveryAI

State today: no MCP code (a case-insensitive grep for "mcp" over `frontend/lib` and `backend-exp/src` only hits unrelated
strings in `composer.dart`, `transcript.dart`, `util.zig`). Chat has a fixed, cache-stable tool set (`backend-exp/src/tools.zig`,
loop in `chat.zig`). Code runs through the OpenHands sidecar whose conversation-create accepts `mcp_config`, unused so far.

### 7a. Code: pass `mcp_config` to OpenHands (do first)

- Settings > MCP servers: list stored in Preferences (like `code.projects`), scope global or per project. Entry: name, stdio
  (command, args, env) or remote (URL, headers).
- `OpenHandsHarness` create body (`frontend/lib/features/code/harness/openhands_harness.dart`) adds `mcp_config` from the merged
  global + project list; this lets the sidecar own the protocol (stdio and HTTP) with zero protocol code in EveryAI.
- UI: MCP calls surface as `MCPToolAction` events; render as a compact StepItem row. Classify MCP tools as non-read-only in
  `AgentMode`/`shell_readonly.dart`: Ask asks, Plan rejects, Full auto passes. Do not trust `readOnlyHint` from untrusted servers.
- Consent: adding a stdio server shows the exact command, flags dangerous patterns (sudo, rm -rf, ssh keys), requires approval,
  reusing `approval_card.dart`. The app is unsandboxed on macOS, so this is real code execution. Keep secrets out of logs.
- Remote servers needing OAuth: do the flow in the app (system browser, loopback redirect, native application type) and pass only
  a short-lived header; tokens never enter the agent context. Later.
- Unknowns to test against the v1.59.0 sidecar: remote Streamable HTTP support, which protocol era it speaks, whether image
  content reaches the model, whether elicitation surfaces.

### 7b. Chat: should the Zig backend be an MCP client?

Yes, but narrowly: **remote Streamable HTTP servers only, per-user**. The stateless 2026-07-28 shape (POST, JSON or SSE) maps
onto Anole's HTTP client and the SSE parser (`net/sse_client.zig`) with no session store or GET stream. stdio servers do not
belong in a hosted backend.

- New `backend-exp/src/mcp_client.zig` plus a migration for `mcp_servers` (user, url, encrypted token). Calls `server/discover`,
  `tools/list` (cached by `ttlMs`), `tools/call`, and handles `input_required` retries. Fall back to `initialize` +
  `Mcp-Session-Id` for legacy servers (most deployed ones); on `UnsupportedProtocolVersion` retry with a supported version.
- Tool merge: namespaced function tools appended **after** the constant system tools, in deterministic order, to keep prompt
  caching intact. Surface as `tool_status` events; map image content to the existing `image` event; map `structuredContent` to a
  UI tool when an outputSchema matches a renderer.
- Auth flow in a Flutter app: start with user-supplied bearer tokens. Full OAuth later: backend discovers PRM/AS metadata,
  publishes a Client ID Metadata Document as EveryAI's client_id (avoids DCR), PKCE S256, `resource` parameter, `iss` check;
  the app opens the system browser and the callback hits `/v1/mcp/oauth/callback`. Tokens are stored per (user, issuer,
  resource). Never forward EveryAI's JWT or sk-eai- key to an MCP server.
- Safety: shared SSRF-safe fetcher (block loopback/private/link-local, pin resolved IP, cap redirects and size); per-server
  and per-tool allow-once/always/deny; tool output treated as untrusted data.
- Cancel: when the app stream drops or Esc is pressed, close the upstream MCP response stream; no `Last-Event-ID` resume,
  re-issue as a new request if the stream breaks. Map MCP progress to `tool_status.detail`.
- Elicitation: new SSE event (for example `tool_input_request`) rendered with the existing question-card widgets; re-call with
  `inputResponses`. Refuse sensitive-field forms; show the server name; URL mode only after domain consent.
- Stopgap for Anthropic-routed models: pass `mcp_servers`/`mcp_toolset` through the native adapter with the beta header. Tools
  only, public HTTP, not available via OpenRouter or the gateway.

### 7c. MCP Apps vs our own UI tools

Our UI tools (`create_artifact`, `render_chart`, `make_quiz`, ...) are native renderers: trusted, themed, cheap, but a closed set.
MCP Apps are third-party HTML views with a standard bridge. Keep both. Add an `ui_view` renderer later that loads the `ui://`
resource into InAppWebView with a CSP (spec default plus declared domains), a unique origin, no shared storage, and a small
AppBridge over a JS handler; forward `_meta.ui.resourceUri` and the fetched resource over SSE; Linux falls back to source. This
depends on 7b and is desktop-first. The spec's sandbox-proxy rules describe web hosts; how a native webview satisfies them is our
inference.

### 7d. Exposing EveryAI as an MCP server

Low priority. A stateless `POST /mcp` in backend-exp (`mcp_server.zig`) implementing `server/discover`, `tools/list` (ordered,
with `ttlMs`/`cacheScope`) and `tools/call` for `web_fetch`, `generate_image`, usage. Auth with the existing `Authenticate{keys}`
middleware (sk-eai- keys, audience-scoped), Origin validation, billing through `billing.zig`, PRM at
`/.well-known/oauth-protected-resource` if OAuth is added. Test with `npx @modelcontextprotocol/inspector --cli`. It could also
serve schemas to the Code agent in place of the `ask_user_question`/`present_plan` client-tool workaround.

## 8. Security checklist

- [ ] stdio server add: exact command shown untruncated, code-execution warning, explicit approval, minimal privileges.
- [ ] MCP tool calls require approval by default; annotations never auto-approve for untrusted servers.
- [ ] Tool list visible to the user; indicator while a tool runs; log view-initiated calls.
- [ ] OAuth: PKCE S256, `resource` param, issuer validation (metadata and `iss`), exact redirect match, rotating refresh tokens.
- [ ] No token passthrough; per-(user, issuer, resource) encrypted storage; never send EveryAI credentials to MCP servers.
- [ ] SSRF-safe fetcher for all discovery and MCP URLs (also fixes `web_fetch`).
- [ ] Treat results from one server as untrusted for another; require approval for write/action tools after untrusted content.
- [ ] Elicitation: show server name; refuse credential requests; URL mode shows full URL, no prefetch.
- [ ] State handles bound to authenticated user ID if we host a server.
- [ ] Origin validation and localhost binding for any local HTTP listener.
- [ ] MCP Apps: enforce CSP, no undeclared domains, host-mediated downloads with confirmation.
- [ ] Do not implement Sampling (server-initiated LLM calls bypass billing).

## 9. Roadmap

1. **M1 (days):** Code `mcp_config` pass-through, Settings list, stdio consent dialog, MCP row rendering, AgentMode rules; test
   against the v1.59.0 sidecar (resolve the unknowns in 7a).
2. **M2:** Render image/resource_link/structuredContent in Code transcript; SSRF-safe fetcher in backend-exp.
3. **M3:** Chat MCP client (bearer tokens, remote HTTP, discover + tools, legacy fallback), per-tool approval, cancel propagation.
4. **M4:** Elicitation to question card (Chat and Code if OpenHands exposes it); prompts as slash commands.
5. **M5:** OAuth (CIMD client, PKCE, resource, iss); in-app flow for Code remote servers.
6. **M6:** MCP Apps view; EveryAI as MCP server; curated connector list (static JSON shaped like `server.json`); Tasks if long
   tools appear.

## 10. Unverified claims

- `schema.ts` was read only for `LATEST_PROTOCOL_VERSION` and tool annotations; error codes and field names come from the
  changelog and prose pages.
- Exact JSON shapes for `InputRequiredResult`/`inputResponses`/`requestState`, and the Tasks extension wire format, were only
  skimmed; read `basic/patterns/mrtr.mdx` before implementing.
- Prompts, completion, caching pages, and `tutorials/security/authorization.mdx` and `local-server-security.mdx` were read at
  heading/normative-line level only; SSRF mitigation specifics and the auth extensions were skimmed.
- OpenHands v1.59.0 `mcp_config` schema, remote HTTP support, protocol era, content forwarding and elicitation: untested.
- TS/Python SDK stateless-era support, and community Dart/Zig MCP packages, not checked.
- Claude API connector beta header names (`mcp-client-2026-09-15`, `mcp-client-2025-11-20`) and `mcp_toolset` shape come from the
  scout and were not re-read; Claude product connector behavior was not fetched.
- MCP Apps citations are to the draft spec; the stable 2026-01-26 version was not diffed. How a native webview meets the
  sandbox requirements is inferred.
- Anole POST-with-SSE-response client behavior was not tested; effort and impact ratings are estimates.
