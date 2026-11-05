---
name: everyai-max
description: How to take on a large or unclear coding task. Research it, ask the user what only they can decide, present a plan, build it in parallel forks, then verify. Load it only when an everyai-workflow note says the user turned Max on.
license: Apache-2.0
compatibility: Code sessions only (a shell, git and the EveryAI coding tools).
---
# Max: research, ask, plan, build in forks, verify

This is an approach, not a script. Take the steps in order when the task needs them, skip what it doesn't need, and keep a small task small.

The tools named here (`fork`, `check_forks`, `answer_fork`, `present_plan`, `ask_user_question`) come from the `everyai` MCP server. Only on the EveryAI harness itself, which has no such server, is `fork` its `run_subagent` tool with `run_in_background: true` (and `worktree` on is `isolation: "worktree"`).

## 1. Research
- Read enough to know which parts of the code the task touches, how they fit, and how the project builds and tests.
- Send a broad question (how does X work across the code, what calls Y) to one or two read-only forks, so your own context stays small.
- Don't change files yet.

## 2. Ask
- Some decisions belong to the user: scope, design, trade-offs, names they will live with. Put those in one `ask_user_question` card, with 1 to 4 questions.
- Give each question 2 to 4 options with a short description. Put your pick first and end its label with " (Recommended)".
- Don't ask what the code or the docs already answer.

## 3. Plan
- Call `present_plan` with a title, a short summary and the steps.
- For each step, say which files it touches and how you will check it works.
- Mark the steps that don't depend on each other: those can run in parallel.
- Wait for the user's answer. Change the plan if they ask for changes.

## 4. Build in forks
- Give each independent step to a `fork`, with `worktree` on so parallel forks don't edit the same files. At most 4 run at once.
- A fork sees nothing of this conversation. Its task must stand alone: the goal, the files, the plan step, the conventions to keep, and how to check the work.
- Do the steps that depend on others yourself, or start their fork once the step before has reported.
- Don't sleep or poll. Each fork's report comes as a `<task-notification>` inside an `<everyai-notice>` (see the notices rule in the session briefing). Use `check_forks` when you want to see how they are doing.
- A `<fork-question>` is yours to answer with `answer_fork`. When the user should decide, ask them with `ask_user_question` first and pass their answer on.
- When `check_forks` says a fork waits for an approval, tell the user: only they can approve it.
- Stop a fork that is stuck, looping or off its task with `stop_fork`. Then redo that step yourself or start a fork with a clearer task.

## 5. Verify
- Read each report and its merge note. Fix any conflict a merge left.
- Run the project's tests and its build or linter. Fix what fails.
- Finish with a short report: what changed, where, and what you checked. Say plainly what is left or didn't work.
