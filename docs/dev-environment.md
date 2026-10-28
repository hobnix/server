# Development environment and agent workflow

How to run the tests, where each kind of test can run, and how the agents in `.claude/agents/` split the work. For people who change the code;
the guides for running a server are the other pages.

## Run tests

One quiet command runs them. It prints failures and one summary line, and keeps every full log in `.work/test-logs/`.

```bash
scripts/dev/t quick pkg docs
```

| Command | What it runs |
| --- | --- |
| `scripts/dev/t quick [name...]` | the tests that need no root (all of them without names) |
| `scripts/dev/t changed` | the tests that mention a file you changed (at most 25; name the rest yourself) |
| `scripts/dev/t root [name...]` | the root tests: loop devices, dm-crypt, mounts (Linux and root, or passwordless sudo) |
| `scripts/dev/t vm` | the throwaway Incus VM test (`zfs-vm`; needs KVM and the internet) |
| `scripts/dev/t wsl quick\|changed\|root` | the same, run inside a Debian WSL (Windows only) |
| `scripts/dev/t list` | the names of the quick, root and vm tests |

Add `-v` for a line per test. `grep -n FAIL .work/test-logs/<name>.log` shows why one failed.

## Where each test can run

| Tier | Where | Covers |
| --- | --- | --- |
| 0 | Linux, macOS, or Windows Git Bash | all quick tests (slow on Windows: use tier 1) |
| 1 | Debian WSL or any Linux, with root | root tests on loop devices: ext4, mergerfs, SnapRAID, LUKS, restic |
| 2 | CI, or a throwaway Incus VM | ZFS and Incus tests, boot and rebuild |

The WSL2 kernel has no ZFS and no `/dev/kvm` (unless nested virtualization is on), so ZFS tests run in tier 2. CI runs the quick tests, the root
tests on a hosted runner, and the NixOS evaluation.

### Set up a Debian WSL (tier 1)

Run once, inside the WSL, as your normal user. It installs the test tools and, only if you say yes, allows passwordless sudo for this
development WSL (remove `/etc/sudoers.d/hobnix-dev` to undo):

```bash
wsl -d Debian -- bash /mnt/c/path/to/the/repository/scripts/dev/wsl-setup.sh
```

Then, from the repository on Windows:

```bash
scripts/dev/t wsl root
```

The runner copies the working tree into `~/hobnix-test` in the WSL (ext4, much faster than `/mnt/c`) and runs the tests there.

## Agents

The main session orchestrates and keeps its context small. It delegates to the agents in `.claude/agents/`, each with its own model and effort:

| Agent | Model, effort | Job |
| --- | --- | --- |
| `architect` | Opus, high | writes `.work/<id>/spec.md` for a task that needs design; never edits code |
| `coder` | Sonnet, medium | implements one spec and writes `.work/<id>/report.md` |
| `implementer` | Haiku, low | mechanical edits from an exact spec |
| `tester` | Haiku, low | runs `scripts/dev/t`, reports failures only |
| `reviewer` | Opus, high | reviews the diff against the spec; read-only |
| `docs-writer` | Sonnet, low | writes guides to `GUIDE-TEMPLATE.md` |

`/work <id>` runs the loop for one task of `TODO.md`: spec, code, test, review. A task id is the section letter and the item number
(`## A.` item 1 is `A1`). Specs and reports are files in `.work/<id>/` (git-ignored); an agent's final message is at most 150 words.

A session starts with a short summary from `scripts/dev/session-context.sh`: the branch, the changed files and the next open tasks.

## Keep the context small

- The root `CLAUDE.md` holds only the rules that always apply. Area rules in `.claude/rules/` (storage, web, packages, commands, shell,
  config, monitoring, instances) load when a matching file is touched; a new fact goes into the rule of its area.
- Check what a session carries with `/context`. Turn off the MCP servers and skills a session does not need (`/mcp`, `skillOverrides`).
- Do not switch the model or the effort in the middle of a session: it empties the prompt cache.
