# Browser OS: a harness check

A long, open-ended task that exercises a harness's automatic tool use,
planning, verification and subagents. It is graded by people, not a script.

How to run it:

1. Create an empty folder, `git init` it and make one commit (so Changes
   works), then add it as a Code project.
2. Start a session with **Sonnet 5.5 · Medium** and **Full auto** for each
   setup you compare (models, tiers, or a build before and after a change; the
   OpenHands harness the first runs compared against is gone). Paste `TASK.md`
   as the first message. Use a separate folder for each run.
3. When each run ends, use **Export transcript…** in the session's menu.
4. Compare the `index.html` files in Chrome and the transcripts: the
   tools used and how, the flow (plans, todo list, questions asked, forks),
   whether it checked its own work, cost and time.
