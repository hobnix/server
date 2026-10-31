---
description: Run one TODO task through spec, code, test and review with the agent set (/work A1)
---
Task: $ARGUMENTS

!`bash scripts/dev/session-context.sh --plain`

You are the orchestrator: keep your own context small, delegate every step, read only the agents' short reports. The rules that always apply are in CLAUDE.md; the OpenCode specifics are in AGENTS.md.
1. Find the task: `bash scripts/dev/session-context.sh --plain --task <id>` prints the full TODO.md item for an id like A1 (id = section letter + number, `## A.` item 1 is A1); no Task block in the output means the id does not exist, then treat the text as the task. Create `.work/<id>/`.
2. If the task is unclear, touches storage, network or the firewall, or has several designs: ask the user one short question first (question tool, recommended option first). Do not guess.
3. Needs design (new feature, several files, a decision)? Delegate to `architect` -> `.work/<id>/spec.md`. A small, obvious change: write the 5-line spec yourself.
4. Delegate the change: `coder` with the spec path (name the area rule file to read). Mechanical and exact (renames, moves): `implementer`. Independent changes in different files may run in parallel; two writers never touch the same file.
5. `tester` runs `scripts/dev/t changed` (and root tests when the spec says so). On failures send the failing check list back to `coder` (twice at most, then stop and ask the user).
6. `reviewer` reviews the diff against the spec. Send real findings back to `coder`.
7. When clean: update the TODO.md item (state and one line), then report to the user in 5 lines: what changed, tests, what was not run, next step. Commit or open a PR only when the user says so.
Never paste file contents, logs or diffs into your own messages; refer to `.work/<id>/` paths.
