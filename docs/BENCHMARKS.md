# Benchmarks

## Harness benchmark: BrowserOS

One prompt (a browser OS in a single file: 5+ apps, two working 3D games, procedural wallpapers, a Messages app, a
special feature), run on several models and companies. Costs are what EveryAI charged, including side calls. Full
stat sheets are in [`benchmarks/browseros/`](benchmarks/browseros/README.md).

| Run | Model | Effort | Tier | Harness | Charged | Cache hit | Wall | Calls | Tools /10 | Result (review) /10 | Result (owner) /10 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| [sonnet-browseros-efficient](benchmarks/browseros/sonnet-browseros-efficient/results.md) | `anthropic/claude-sonnet-5.5` (Anthropic) | medium | Efficient | EveryAI | $1.550 | 91.5% | 10.4 min | 15 | 7 | 7.5 | **7** |
| [sonnet-browseros-thorough](benchmarks/browseros/sonnet-browseros-thorough/results.md) | `anthropic/claude-sonnet-5.5` | medium | Labelled **Thorough** | EveryAI | $3.399 | 94.8% | 23.8 min | 28 | 8 | 8.5 | **9** |
| [terra-browseros-max](benchmarks/browseros/terra-browseros-max/results.md) | `openai/gpt-6.1-terra` | medium | Max | EveryAI | $0.952 | 91.3% | 4 h 09 min | 126 | 5 | 7.5 | **6** |
| [kimi-browseros-max](benchmarks/browseros/kimi-browseros-max/results.md) | `moonshotai/kimi-k2.6` | medium | Max | EveryAI | $1.438 | 92.9% | 14.0 min | 120 | 5 | 6.5 | **5** |
| [deepseek-flash-browseros-medium--max](benchmarks/browseros/deepseek-flash-browseros-medium--max/results.md) | `~deepseek/deepseek-flash-latest` | medium | Max | EveryAI | $1.480 | 95.7% | 23.2 min | 561 | 9 | 8.5 | **9** |
| [open-hands-impl-sonnet-medium](benchmarks/browseros/open-hands-impl-sonnet-medium/results.md) | `anthropic/claude-sonnet-5.5` | medium | Efficient | OpenHands agent-server | $7.778 | 12.6% | 29.2 min | 34 | 6 | 7 | **9** |

These runs predate the multi-harness work (2026-10-30/31): every row is the EveryAI harness except the OpenHands
baseline. In every EveryAI run 91–96% of prompt tokens were cached; the OpenHands baseline hit 12.6% and cost 2–5×
more for the same model and task.

Not yet measured: outside agents (Claude Code, Codex, OpenCode) on the same task, and wall-clock time, tool-call
count and check-run count per run (planned in the agent eval).
