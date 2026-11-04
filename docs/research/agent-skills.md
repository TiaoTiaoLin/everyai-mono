# Agent Skills: standard, Claude integration, and what EveryAI should do (2026-10-30)

Research doc. Read-only study of the open Agent Skills standard, Anthropic's example skills, and how skills fit
Chat and Code. Companion: [mcp.md](mcp.md) if present (MCP protocol study). Citations are `repo/path:lines` under
the local clone root `/private/tmp/claude-501/mcp-skills-research`. Claims from Anthropic web docs that were
read from a fetched page but not re-checked here are tagged `[web]`; things not verified are in the last section.

## 1. Sources

| # | Source | License | Pin |
|---|---|---|---|
| 1 | Agent Skills standard, https://github.com/agentskills/agentskills (site agentskills.io) | Code Apache-2.0, docs CC-BY-4.0 (`agentskills/README.md:57-59`) | 69ef37e (2026-08-09), SHA 69ef37e9424c0a7ea9dd2293b559e43ec8176379 |
| 2 | Anthropic example skills, https://github.com/anthropics/skills | Mixed, see section 4 | ca45fc4 (2026-10-28), SHA ca45fc496a3436251f191354091d557da31c15b5 |
| 3 | MCP Skills extension overview (SEP-2640, `io.modelcontextprotocol/skills`) in https://github.com/modelcontextprotocol/modelcontextprotocol | MCP is moving MIT to Apache-2.0; docs CC-BY-4.0 | 84d8457 (2026-10-29) |
| 4 | OpenHands skills docs, https://docs.openhands.dev/overview/skills `[web]` | MIT project | not pinned |
| 5 | Claude docs: platform.claude.com agent-skills overview, skills-guide; code.claude.com/docs/en/skills `[web]` | Anthropic docs | fetched 2026-10-30, partly read |
| 6 | Not cloned: modelcontextprotocol/ext-skills (the normative SEP-2640 text) | | |

`anthropic-skills/spec/agent-skills-spec.md` is only a stub pointing to agentskills.io/specification.

## 2. Executive summary: top 10 for EveryAI

| # | Item | Impact | Effort |
|---|---|---|---|
| 1 | Code: put SKILL.md folders where OpenHands already looks (`.agents/skills/`) and add a Skills screen. First do a 30-minute live check that agent-server 1.59.0 actually loads them. | high | S |
| 2 | Chat: `load_skill` server tool in backend-exp. Catalog (name + description) in the tool description, body returned as tool result. Instruction-only skills, no sandbox. | high | M |
| 3 | Skills library UI in Settings: list, enable toggle, import folder/zip, validation result. | high | M |
| 4 | `/skill-name` slash menu in both composers for explicit activation. | high | S |
| 5 | Ship original Apache-2.0 skills that steer our existing UI tools (`make_slides`, `create_artifact`, `render_diagram`) instead of copying document skills. | high | M |
| 6 | Strict validator on import (port skills-ref rules), lenient on load. | medium | S |
| 7 | Trust gate for project-level skills from cloned repos. | medium | S |
| 8 | Script-bearing skills run only in Code; mark them "needs Code" in the library. | medium | S |
| 9 | Starter pack from Apache-2.0 skills (skill-creator, mcp-builder, frontend-design, theme-factory), license + SHA in a notice file. | medium | S |
| 10 | Skill activations as `tool_status` events and in usage attribution; reuse `tool/agent_eval` for trigger-rate evals. | low | M |

Out of scope until a product decision: a server-side code-exec sandbox (large), forwarding Anthropic `container.skills` (Anthropic-only), Skills over MCP.

## 3. The standard

**Layout.** A skill is a directory with a required `SKILL.md`; optional `scripts/`, `references/`, `assets/`, and any other files
(`agentskills/docs/specification.mdx:6-17`, `:187-237`).

**Frontmatter** (`specification.mdx:25-32`; verified against the table):

| Field | Required | Constraint |
|---|---|---|
| `name` | yes | max 64, lowercase letters/digits/hyphens, no leading/trailing hyphen (no consecutive hyphens), must match the parent directory name |
| `description` | yes | 1-1024 chars, what it does and when to use it |
| `license` | no | name or bundled file reference |
| `compatibility` | no | max 500, environment needs |
| `metadata` | no | string-to-string map (put a `version` here) |
| `allowed-tools` | no | space-separated pre-approved tools (experimental) |

The body is free Markdown. There is no version field in the spec; authors use `metadata.version`
(`specification.mdx:44-55`, `:147-161`).

**Progressive disclosure** (`specification.mdx:216-224`; `client-implementation/adding-skills-support.mdx:18-30`):
1. Catalog: name + description for every skill, about 50-100 tokens each, loaded at startup.
2. Body of `SKILL.md` on activation: under 5000 tokens, under 500 lines recommended.
3. `scripts/`, `references/`, `assets/` only when the body references them. Script code stays out of context; only output enters.

**Validator.** `agentskills/skills-ref` (Python, demo only per its README) enforces the limits and rejects any frontmatter key
outside `{name, description, license, allowed-tools, metadata, compatibility}`
(`skills-ref/src/skills_ref/validator.py:10-22`, spot-checked). `to_prompt` emits the `<available_skills>` XML.

**Client implementation guide** (`adding-skills-support.mdx`):
- Discover project and user scopes, in a client-specific directory plus the cross-client `.agents/skills/` (`:45-58`). Skip `.git` and `node_modules`; bound depth 4-6 and about 2000 directories (`:79`, verified). Project overrides user on name collision.
- Parse leniently: warn on name/directory mismatch, skip if description is missing or YAML is unparseable, retry with quoting for colon values.
- Disclose: `<available_skills>` with name, description, location, in the system prompt or a tool description. Hide filtered skills; omit the block when empty.
- Activate: model reads the file, or a dedicated tool takes a name; make `name` an enum and do not register the tool when there are no skills (`:255`, verified). Wrap content in `<skill_content name=...>`, list bundled resources without eagerly reading them (`:306`).
- Manage: exempt skill content from context compaction, dedupe repeat activations, gate project skills on trust.

**Authoring guidance.** Evals: run each case with and without the skill, record tokens and time, grade by assertions
(`skill-creation/evaluating-skills.mdx:48-127`). Description tuning: about 20 trigger queries (8-10 should, 8-10 should not),
3 runs each, 0.5 trigger-rate threshold (`optimizing-descriptions.mdx:28-91`).

**Example SKILL.md** (valid per the above; this is the shape EveryAI would ship):

```markdown
---
name: make-deck
description: Plan and write a slide deck with the make_slides tool. Use when the user asks for a presentation, pitch, or slides.
license: Apache-2.0
metadata:
  version: "1.0"
---

# Make a deck

1. Ask for audience and length if missing; default to 8 slides.
2. One idea per slide, titles are claims, at most 5 bullets.
3. Put speaker notes on every slide.
4. Call `make_slides` once with the whole deck, then offer PPTX export.

See references/themes.md for the four built-in themes.
```

**Adoption.** `agentskills/docs/snippets/clients.jsx` lists 46 products including Claude, Claude Code, OpenHands, Cursor,
Gemini CLI, GitHub Copilot, VS Code, Codex, Goose. `.agents/skills/` is a de facto cross-client convention
(`adding-skills-support.mdx:54`).

## 4. How Claude products and the API run skills

All surfaces use the same progressive-disclosure idea. Differences are in execution. `[web]` unless noted.

| Surface | Where skills live | Execution | Notes |
|---|---|---|---|
| Claude API | `container.skills=[{type:"anthropic"\|"custom", skill_id, version}]` (max 20) with the code execution tool | sandbox container, no network, no package installs | pre-built ids `pptx`, `xlsx`, `docx`, `pdf`; custom upload via `POST /v1/skills`; outputs come back as `file_id`, fetched via Files API |
| Claude Code | `~/.claude/skills`, `.claude/skills`, nested, plugins, enterprise | local disk, full network | extra frontmatter: `disable-model-invocation`, `user-invocable`, `when_to_use`, `context: fork`, `model`, `hooks`, `paths`, etc.; listing truncated at 1,536 chars per skill; after compaction first 5,000 tokens kept per skill within 25,000 |
| claude.ai | per-user zip upload (Settings > Features) | hosted code execution | no admin distribution; does not sync with API or Claude Code |
| OpenHands | `.agents/skills/` (preferred), `.openhands/skills/`, `.openhands/microagents/`, `~/.agents/skills/`, public registry | agent-server | triggers (keywords), `paths` rules, or model-invoked by description; project > user > public |

Outside Claude Code, claude.ai and the API reject any field outside the six spec fields; the API also forbids XML tags and the
reserved words `anthropic`/`claude` in `name`. Anthropic's guidance: use only trusted skills, audit bundled files.
Gotchas for us: the pre-built document skills are not available in Claude Code, and the Skills API path needs the code-execution
container, which our OpenAI-compatible tool loop and `anthropic.zig` adapter do not forward.

Security rules from the MCP Skills extension (`mcp-spec/docs/extensions/skills/overview.mdx:408-422`, verified):
same-name skills must not silently replace each other, loaded content is tagged with its origin, skill content is untrusted
input, code execution and `allowed-tools` need explicit per-skill approval, nested skills need fresh consent.

## 5. Example skills worth reusing (license column)

License verified by reading each `LICENSE.txt` head in `anthropic-skills/skills/*` at ca45fc4.

| Skill | License | May we copy? | Use for EveryAI |
|---|---|---|---|
| skill-creator | Apache-2.0 | yes, with notice | eval loop + description optimizer; adapt for Code |
| mcp-builder | Apache-2.0 | yes | Code starter; ties skills to MCP |
| frontend-design | Apache-2.0 | yes | Code and Chat HTML artifacts |
| theme-factory | Apache-2.0 | yes | 10 themes; map to our 4 slide themes |
| canvas-design, algorithmic-art | Apache-2.0 | yes | prose-heavy design philosophies; render via code |
| brand-guidelines | Apache-2.0 | yes but Anthropic-specific colors/type, little reuse | pattern only |
| web-artifacts-builder, webapp-testing, slack-gif-creator, internal-comms, claude-api, discernment-nudge, academy-guide | Apache-2.0 (LICENSE.txt present) | yes | situational |
| doc-coauthoring | no LICENSE.txt and no `license` field in the folder (the scout notes assumed Apache-2.0; not confirmed) | ask or treat as reference only | workflow pattern |
| docx, pdf, pptx, xlsx | proprietary: "All rights reserved", no copying, derivatives, or distribution | no. Reference only. | patterns only: decision table + gotchas in SKILL.md, scripts run in a sandbox with node/python/LibreOffice |

The README says these four are "source-available, not open source" (`anthropic-skills/README.md:20`). Do not bundle or paraphrase
their scripts.

## 6. Skills in EveryAI

Today: no skill concept in `backend-exp/src` or `frontend/lib`. Chat has a constant, cache-stable prompt and tool JSON
(`tools.zig`). Code runs the OpenHands sidecar and passes `workingRules` via `agent_context.system_message_suffix`.
EveryAI already makes PPTX in Dart (`features/artifacts/export`) and renders html/svg/slides artifacts, so Chat covers the output
side of document skills without a sandbox. Media tooling choices are in `docs/research/media/README.md`.

### 6.1 Code (OpenHands)

- Provision enabled user skills into `<worktree>/.agents/skills/` and keep it git-excluded like `.everyai/uploads`. User skills also in `~/.agents/skills/`.
- Verify first: does agent-server 1.59.0 scan `.agents/skills/`? The docs page may describe a newer SDK. If not, read SKILL.md ourselves and inject the catalog through `agent_context`. Check field names in the 1.59.0 OpenAPI.
- Trust gate: skills in a freshly cloned repo load only after the user marks the project trusted (guide recommendation). Store flag in Preferences next to `code.projects`.
- Settings > Skills: project and user lists, enable toggles, import (copy from `~/.claude/skills`), validation badge.
- Script-bearing skills are fine here; the sidecar has a terminal.
- `mcp_config` is accepted by conversation create; the media research already proposes MCP servers through it.

### 6.2 Chat, without a sandbox (phase 1)

- New `backend-exp/src/skills.zig`: discovery, frontmatter parse, validator.
- Tool `load_skill(name)` where `name` is an enum of the user's enabled skills; result is `<skill_content name="...">` with the body (frontmatter stripped) and a resource list; `read_skill_file(name, path)` for references. Dedupe within a conversation.
- Cache: the catalog must be sorted and timestamp-free, and live in the tool description or after the constant prompt, so existing cache breakpoints survive. A per-user catalog changes the tool JSON, so cache is per user; acceptable.
- Only instruction/reference skills appear in the Chat catalog. Skills whose `scripts/` or `compatibility` imply execution show "needs Code".
- Seed original skills: `make-deck` (make_slides), `write-report` (create_artifact), `diagram-style` (render_diagram, render_svg), plus a few Apache-2.0 imports.
- Emit `tool_status` for activations; show the token cost in the context ring.

### 6.3 Chat, with a server-side sandbox (phase 2, needs a decision)

| Option | Gives | Cost |
|---|---|---|
| A. Run script skills only in Code | nothing new in Chat | none |
| B. Own sandbox tool (container with python/node/LibreOffice) | pdf/docx/xlsx for every model | large: isolation, quotas, file events, billing |
| C. Forward Anthropic `container.skills` + code execution when the Anthropic route is on | official pptx/xlsx/docx/pdf for Claude models | Anthropic-only, key-holder's workspace, `file_id` download, not ZDR, `anthropic.zig` and a new SSE file event |

Recommendation: ship A now; decide B vs C after the phase-1 library is used. Cheaper alternative for documents: add DOCX/PDF
exporters in the app next to the existing PPTX writer, so no model skill is needed.

## 7. Skills and MCP

- Different layers: MCP exposes tools, resources and prompts for actions; a skill is instructions plus files for a procedure. A skill can tell the model how to use MCP tools (mcp-builder is a skill about writing MCP servers).
- SEP-2640 (status Final per the scout; overview at `mcp-spec/docs/extensions/skills/overview.mdx`) serves skills over MCP: server declares the `io.modelcontextprotocol/skills` extension, lists skills, files read via `resources/read` at `skill://` URIs. Reading `SKILL.md` does not activate it (`overview.mdx:45`, verified).
- If EveryAI adds an MCP client, treat remote skills as untrusted: key by (server, URI), approve per skill, bind approval to a content digest. Key the local store by `(source, uri)` now to avoid a migration.

## 8. Roadmap

1. (S) Live-test `.agents/skills` in the bundled agent-server; record result here.
2. (S) Dart `skill_frontmatter` validator + tests; Settings > Skills read-only list for Code.
3. (M) `skills.zig`, `load_skill`/`read_skill_file`, skills table via migrations, Chat catalog, `/skill` slash menu.
4. (S) Trust gate, import from `~/.claude/skills`, starter pack with notice (license + SHA ca45fc4).
5. (M) Original EveryAI skills for slides/reports/diagrams; trigger evals via `tool/agent_eval`.
6. Later: sandbox decision (6.3), DOCX/PDF exporters, Skills over MCP.

## 9. Unverified

- Which directories and frontmatter fields OpenHands agent-server 1.59.0 honours; the docs.openhands.dev page was not re-fetched in this pass.
- Skills API beta headers and the last part of the Claude Code skills page; Agent SDK skills page, best-practices page, engineering blog post and support.claude.com articles were not read.
- The full SEP-2640 text (ext-skills repo) was not cloned; only the docs overview.
- doc-coauthoring has no license file; I did not find its terms.
- The internals of docx/pdf/xlsx scripts were not read beyond SKILL.md.
- No Agent Skills spec version or changelog scheme found; the commit date is the only pin.
- Whether non-Anthropic models handle an enum-constrained `load_skill` tool well is untested.
- The count of 46 adopters comes from `clients.jsx` and was not recounted; `compatibility`-based "needs Code" detection is a heuristic.
