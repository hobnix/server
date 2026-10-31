# Hobnix server — OpenCode layer

`CLAUDE.md` is the rulebook of this repo for every coding tool; OpenCode loads it through `instructions` in
`.opencode/opencode.jsonc`. Everything in it applies here too: safety rules, generated files, testing through
`scripts/dev/t`, honest reports, the agent workflow, git hygiene. The repo is also worked on with Claude Code
(`.claude/`); keep both tool sets in step, do not reformat or duplicate its files.

## What is different in OpenCode

- **Area rules do not load by themselves.** Claude Code auto-attaches `.claude/rules/*.md` by path; here the matching
  rule file must be read before touching those paths. Match by the `paths:` frontmatter of the rule: storage, web,
  packages, commands, shell (any `*.sh`), config, monitoring, instances. Subagents get CLAUDE.md and this file as
  instructions, but not the area rules: name the rule file to read when you delegate.
- **Session start:** the `session-context` plugin (`.opencode/plugins/session-context/`) injects branch, open
  TODO.md items, last test log and specs in progress into the first request of a session (subagents excluded). If
  it is not loaded, run `bash scripts/dev/session-context.sh --plain` once instead.
- **Agents:** the roles from CLAUDE.md run as `.opencode/agents/` on opencode-go models — architect
  `kimi-k3.1-pro#high` (design, writes `.work/<id>/spec.md`), coder `kimi-k2.7-code` (implements one spec),
  implementer `gpt-6-luna#low` (mechanical edits), tester `beam-free#low` (free model: runs `scripts/dev/t`,
  failures only), reviewer `gemini-4-argon#high` (diff against spec, read-only), docs-writer `gpt-6-luna#medium`
  (guides from the code). `/work <id>` runs the full loop for one TODO.md task.
- **Worktrees** are created under `.opencode/worktrees/` (git-ignored, like `.claude/worktrees/`). The rules,
  agents and plugin apply there too (tracked files, config from the canonical checkout); the session context
  reflects the worktree's own branch and status. Caveat: `bash` on this machine is WSL, and its Linux git cannot
  follow a worktree's `.git` pointer — `session-context.sh` falls back to `git.exe` there; call git through the
  shell tool (PowerShell) inside worktrees.
