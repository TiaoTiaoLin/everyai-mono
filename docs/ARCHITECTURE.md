# Architecture

<img alt="Flutter 3.47" src="https://img.shields.io/badge/Flutter-3.47-02569B?style=flat-square&logo=flutter&logoColor=white"/>
<img alt="Riverpod 3" src="https://img.shields.io/badge/Riverpod-3-00A0C6?style=flat-square"/>
<img alt="Drift" src="https://img.shields.io/badge/Drift-SQLite-003B57?style=flat-square&logo=sqlite&logoColor=white"/>
<img alt="Deno" src="https://img.shields.io/badge/Deno-workflows%20%C2%B7%20scripts-000000?style=flat-square&logo=deno&logoColor=white"/>
<img alt="Zig 0.17" src="https://img.shields.io/badge/Zig-0.17-F7A41D?style=flat-square&logo=zig&logoColor=white"/>
<img alt="Anole 0.5.1" src="https://img.shields.io/badge/server-Anole%200.5.1-9C85FC?style=flat-square"/>
<img alt="ACP" src="https://img.shields.io/badge/agents-ACP%20%C2%B7%20MCP-2CCCEB?style=flat-square"/>

EveryAI is a Flutter app that does the work on the user's own computer, plus a small optional backend. Coding agents
run as local processes; the app talks to each one in its own protocol and gives all of them the same workspace.

## The pieces

```mermaid
flowchart LR
    subgraph App["Flutter app (desktop)"]
        UI["Session view<br/>transcript · composer · panes"]
        CTRL["Session controller<br/>approvals · checkpoints · handoff"]
        DRV["Drivers"]
        HOST["Local MCP host<br/>checks · notes · forks · workflows"]
        WF["Workflow engine<br/>workflow.js in Deno"]
        GIT[("git worktrees<br/>checkpoints")]
    end
    subgraph Agents["Agent processes"]
        EH["EveryAI harness<br/>(in the app)"]
        CC["Claude Code<br/>stream-json"]
        CX["Codex<br/>app-server"]
        OC["OpenCode<br/>serve API"]
        ACP["ACP agents<br/>Antigravity · Cursor · …"]
    end
    Remote["Phone · tablet · web"]
    subgraph Backend["backend-exp (optional)"]
        API["/v1: chat loop · gateway<br/>models · remote relay"]
    end
    Models["Model providers<br/>your key"]

    UI <--> CTRL
    CTRL <--> DRV
    DRV <--> EH & CC & CX & OC & ACP
    CC & CX & OC & ACP -- "MCP" --> HOST
    HOST <--> WF
    CTRL <--> GIT
    EH -- "BYOK" --> API
    UI -- "Chat" --> API
    API --> Models
    Remote <-- "E2E relay" --> API
    API <-- "E2E relay" --> CTRL
```

- **Drivers** (`frontend/lib/features/code/drivers/`): one per protocol. Each turns its agent's events into the
  shared transcript (keeping the agent's own tool names, todos and plans), routes its approvals through the session,
  and reads its slash commands and modes. Outside agents run on the user's own install and sign-in.
- **The EveryAI harness** (`harness/everyai/`): our own agent loop in the app, for any model on the user's key: tools
  per model family, approvals with a hard safety floor, compaction, forks in worktrees, a browser and screenshots.
- **The local MCP host** (`host/`): a loopback MCP server with a token per session. It serves every agent the same
  increments: `check`, `bug_check`, `diff_stats`, `goal_check`, `run_script`, memory and saved plans, Max's fork
  tools, and the workflows as MCP prompts. None of them spends EveryAI money.
- **Workflows** (`workflows/`, `assets/workflows/*.js`): Ultra, Bug fix and Security review run as JavaScript in the
  bundled Deno sandbox (`agent`, `parallel`, `pipeline`, `phase`, schema-checked results). Each `agent()` call can run
  on any listed agent, in its own worktree.
- **Handoff and resume** (`handoff/`, `resume/`): a session can move to another agent (native import into its session
  format where possible, otherwise facts plus the transcript file) and earlier sessions of any agent can be reopened.
- **Git** (`git/`): a worktree and branch per session, a checkpoint per turn, rewind for every agent.
- **Remote control** (`features/remote/`): phones, tablets and the web pair with the desktop and mirror its sessions
  over an end-to-end encrypted relay; the computer runs every session.
- **Chat** (`features/chat/`, `features/artifacts/`): the chat client, artifacts, exports and history (Drift, on the
  device).

## The backend

`backend-exp/` (Zig 0.17 on [Anole](https://github.com/xuckless/anole)) is optional for Code with outside agents. It
provides the chat tool loop (SSE), an OpenAI-compatible gateway the EveryAI harness uses, the model catalog, images,
and the remote-control relay. In the dev build it holds no provider keys: calls run on the key the user adds in the
app. The full `/v1` contract is in [`AGENTS.md`](../AGENTS.md#v1-contract-backend-exp--app); setup and endpoints are in
[`backend-exp/README.md`](../backend-exp/README.md).

## Repository

| Path | What |
|---|---|
| [`frontend/`](../frontend) | The app: Code workspace, drivers, MCP host, workflows, Chat, artifacts, remote control |
| [`frontend/packages/everyai_markdown`](../frontend/packages/everyai_markdown) | Streaming Markdown renderer: math, highlighting, citations |
| [`backend-exp/`](../backend-exp) | The optional `/v1` server (Zig on Anole) and its [deployment](../backend-exp/deploy/README.md) |
| [`docs/`](.) | Roadmaps, this file, [benchmarks](BENCHMARKS.md), research notes |
| [`scripts/`](../scripts) | `launch.sh` (app against the dev server) and `dev.sh` (local backend + app) |

## Platforms

| | macOS | Windows | Linux | iOS | Android | Web |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **Code workspace and agents** | ✅ | build only, not yet tested | build only, not yet tested | remote control | remote control | remote control |
| **Chat and artifacts** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Checked so far** | daily driver | CI build | CI build | simulator | — | ✅ |

One codebase draws four design languages: Cupertino, Material, Fluent and Adwaita-style.
