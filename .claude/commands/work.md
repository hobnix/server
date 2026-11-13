---
description: Run one board issue through spec, code, test and review with the agent set (/work <issue number>, e.g. /work 431)
argument-hint: <issue number, or a short task text>
disable-model-invocation: true
---
Task: $ARGUMENTS

You are the orchestrator: keep your own context small, delegate every step, read only the agents' short reports.
1. Read the issue: `bash scripts/dev/board.sh show <number>` (or treat short text as the task). Create `.work/<number>/` and move the issue: `bash scripts/dev/board.sh move <number> in-progress`.
2. If the task is unclear, touches storage, network or the firewall, or has several designs: ask the user one short question first (AskUserQuestion, recommended option first). Do not guess.
3. Needs design (new feature, several files, a decision)? Delegate to `architect` -> `.work/<id>/spec.md`. A small, obvious change: write the 5-line spec yourself.
4. Delegate the change: `coder` with the spec path. Mechanical and exact (renames, moves): `implementer`. Independent changes in different files may run in parallel; two writers never touch the same file.
5. `tester` runs `scripts/dev/t changed` (and root tests when the spec says so). On failures send the failing check list back to `coder` (twice at most, then stop and ask the user).
6. `reviewer` reviews the diff against the spec. Send real findings back to `coder`.
7. When clean: comment on the issue with the result (`gh issue comment <number> --repo hobnix/server`) and move it to In Review (`board.sh move <number> in-review`; `done` if every box is ticked and run). Then report to the user in 5 lines: what changed, tests, what was not run, next step. Commit or open a PR only when the user says so.
Never paste file contents, logs or diffs into your own messages; refer to `.work/<id>/` paths.
