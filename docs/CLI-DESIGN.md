# Design language of the `hs` commands

One look for every command a person runs on a terminal. The model is `hs update`: a blue heading, one slim line per step with a
status mark, dimmed detail lines indented underneath, and a spinner with the last lines of its output for anything that takes
time. Everything comes from `scripts/lib/ui.sh`; a script never prints its own colours or boxes.

```
▸ Update                                 heading: bold blue, one blank line before it
  ⣾ Fetching the latest configuration (0:07)       a running step (spinner, time after 3 s)
      Receiving objects: 63% ...                   the last lines of its output, dimmed, indented 6
  ✓ 3 new change(s):                               done: green, indented 2
    manage-pool: formatting is one spinner line    detail: dim, indented 4
  ! Local changes in /etc/nixos                    attention: yellow
  ✗ The sync did not finish                        failure: red, ends the command
```

## The components (all in `scripts/lib/ui.sh`)

| Need | Component | Notes |
| --- | --- | --- |
| a heading | `step "Title"` | with gum `▸ Title`; after `steps N` (how many headings the command prints, the count survives `exec`) a tree: `├ Title` for the first and middle ones, `└ Title` for the last; `── Title ──` without gum |
| something is done / remark / attention / failure | `ok` `note` `warn` `fail` | indent 2, 4, 2, 2; `fail` exits 1 |
| a step that takes time | `spin "Title" cmd...` | output only on failure; `SPIN_STREAM=1` prints the newest progress line once a minute without a terminal (jobs, logs); long steps must print progress lines |
| a fact | `kv "Label" "value"` | label dimmed, aligned at 16 characters, indent 4; `KV_WIDTH=22 kv ...` for a block with longer labels (disk-health details) |
| one question with a free answer | `ask "Question" [default]`, `ask_secret` | Enter keeps the default |
| yes or no | `confirm "Question"` | |
| pick one of a list | `choose "Header" line...` | gum list, numbered list without gum |
| pick one of keys with a description | `menu "Header" key "text"...` | returns the key; the way "which pool", "what to add" are asked |
| pick several | `choose_multi "Header" line...` | space selects; the disk lists |
| the line before something is erased | `danger "ALL DATA ... erased"` | bold red |
| the typed confirmation | `confirm_name <name> "what"` | type the NAME OF WHAT IS CHANGED (the disk), not the pool; same word every time |
| a table | `table` (stdin, tab separated, first line is the header) | with gum: indent 2, dim bold header with a thin rule, first column blue, a status in the LAST column coloured (ok/running/ONLINE green; failed/BAD/DEGRADED red; WATCH yellow; never/-/off dim); without gum plain `column -t` (unchanged) |
| help text | `help_usage` `help_section` `help_item` `help_cmd` `help_note` | the base of `hs help` and `hs help <command>`: blue `▸` heading, the command in blue, its arguments dimmed, the description underneath; long lines wrap at the terminal width and keep their indent; plain output is exactly the old text (cmp-checked); homeserver-cli on Windows copies this layout |
| a summary line | `status_line "Problems" "None" ok` | `  Problems: None ✓` on top of a status command; value in the colour of the severity (ok green ✓, warn yellow !, bad red ✗) |
| a plain sentence | `line "text"` | indent 2, normal colour |
| output of another program (journal, log, a tool's lines) | `trail` (stdin) | indent 6, dimmed: the "trailing output" of rule 2; `spin` prints its failure tail the same way |
| closing text | `box` | |
| where to go next | `next_step "hs rebuild"` | dim line at indent 4: `Next: hs rebuild` (German: Als Nächstes) |
| a failure with its fix | `fail_fix "text" "hs command"` | red `✗` line, then `Fix: hs command` dim, both on stderr, exit 1 |
| how long it took | `elapsed_line` | `  ✓ Finished in 2:05`; counted from the first source of ui.sh (`HS_T0`, kept across `exec`, so `hs update` includes the rebuild); silent under 5 s |

## Who gets which form (decided 2026-10-05)

- **User commands** (`hs <command>`, a person at a terminal) are the only ones that use gum and the components below. Every line a person
  reads goes through a component, indented as in the table at the top; no raw `echo`/`printf` text, no own colours or alignment.
- **System commands** (`hs sys ...`) are the machine form for the interface, timers and tools: plain text, never gum, even on a terminal
  (`lib/hs.sh` sets `HS_PLAIN=1` for every `sys` row). A tool that calls the server over SSH (the interface's background reads, timers,
  `homeserver-cli`) calls only `hs sys ...` rows, with `HS_CALLER=cli` (or `ui`, `timer`, `job`, `test`) so the "this is a system command"
  question stays quiet. Where a tool needs something that only has a user form, add a `sys` row for it (`hs sys unlock stdin`,
  `hs sys motd status`), never rely on the output of a user command being plain.
- **`homeserver-cli`** (Windows) is the client of those `sys` rows and looks and feels like the user commands on the server: the same
  headings, indents, colours and help layout (see "Help text" above), drawn by its own `ui.rs`.
- **Status commands** start with a summary line, `status_line "Problems" "None" ok` -> `  Problems: None ✓` (warn `!` yellow, bad `✗`
  red), then a `table` for the rows, then `line`s for the closing facts. `line "text"` is a plain sentence at indent 2.
- **A list that scripts also read** (`hs share <share> snapshots`, `hs snapshots list`): a person at a terminal (`[ -t 1 ]`, `HS_CALLER`
  unset) gets `thead` + `table` (and a `status_line`); a pipe gets the old tab separated lines, because the guided dialogues, the tests and
  tools read them. The tab form is never changed for the looks. `die()` in `backup.sh` and `temp-disk.sh` is `fail "$@" >&2`: the red
  line on stderr. Trailing output of programs (restic lists, `zpool status`, `df`) is indented by `sed 's/^/      /'` (6) or 2 for lists.

## Rules

1. **Same look with and without gum.** Without gum (or a pipe, a timer, `HS_PLAIN=1`) the same lines print as plain text with the
   same structure; the components decide, the script never tests for gum itself. A question never falls back to a different
   program (no whiptail) except in the installer (`manage-pool.sh --plain`, the system has no gum there).
2. **Indentation is part of the design:** headings at the margin, results at 2, details at 4, trailing output at 6.
3. **Plans are lines the interface reads** (`Plan:`, `Command:`, `Note:`, `ALL DATA`, `Dry run`, `Current array`): their text and
   prefixes do not change and are not translated; colours are added only with gum on a terminal. Anything the interface parses
   (`--list`, `--info`, `--members`, `--dry-run`) stays plain and unchanged.
4. **Destructive commands** show what happens (a plan), then `danger`, then `confirm_name` with the name of the disk or object, then
   (for long work) the offer of a background job. Never a bare "y/N" for erasing.
5. **Text is the key for the German translation** (`scripts/lib/i18n/de.tsv`): static text goes through the components, text with
   values through `$(t 'Copied %s files' "$n")`.
6. **Long steps show where they are** (progress lines, `SPIN_STREAM`), never a silent minute.

## Where it is applied

- Done: `update`, `rebuild`, recipes, `backup`, `manage-ct`, `manage-users`, `manage-shares`, `create-share`, `recipe`, `mac`, `jobs`,
  `ssh-key`, `ports`, `ct update-all`; `manage-pool` since 2026-10-05: the questions (which pool, what to add, which disks) are
  `menu`/`choose_multi`, the typed confirmation is `confirm_name`.
- `manage-pool` plans and summaries since 2026-10-05: with gum a plan is a `step` heading (`Plan: ` dropped), indented numbered steps,
  `kv "Command"` for the command, a `danger` line before erasing, `warn` for notes and a closing `ok`; the "Current array" block is a
  heading with `kv` rows. The helpers are `phead pl plt pcmd pplan pnote pwarn pdanger pdry pdone` in `scripts/manage-pool.sh` (each
  prints the old line unchanged when `$ui` is not gum). **Plain output is byte for byte what it was**: `tests/pool-look.sh` compares
  14 dry-run plans (ZFS and SnapRAID) with `tests/pool-look/*.out`, recorded from the script before the restyling.
- The same script runs bare for the interface's hand-over: `hs pool <pool> replace|remove|convert` without a disk asks which one
  (`menu` over `--members`: size, state, filesystem, encryption; convert lists only online data disks; replace then asks the free
  disk), `add` asks role and disks; these four registry rows are flagged `guided`. Without a terminal and without a member the usage
  line stays. Questions for disks that get formatted come in the order of : encrypt?, filesystem, passphrase
  (a new ZFS pool is asked about encryption too). `tests/pool-bare.sh` feeds the answers on stdin (`HS_GUIDED_TTY=1`).
- Consistency sweep of the system/status commands (2026-10-05): `doctor` (one `status_line` per section: Problems, Failed jobs,
  Storage, System, then Overall under a "Result" heading; the lines of a section are collected and printed under its summary),
  `system info|rollback|gc` (`kv` rows, `spin` for the long steps), `config list`, `secrets`, `cleanup`, `smoke`, `ports`, `jobs`, `ssh-key list`,
  `first-run`, `migrate [--status]`, `migrate check`, `hs ct list` (status.sh) all open or close with a `status_line`; every table has its
  `thead`; journals and logs go through `trail`; `hs help --search` and the "unknown command" messages use `help_section`, `help_item`,
  `warn`, `line`. Left plain on purpose: `notify --dry-run` (a plan), `motd` (the interface and homeserver-cli parse its lines),
  `report` (writes a file), `config get` (a bare value for scripts).
- Still plain `echo` blocks with their own layout: `share-cache`, `docs-build`, `health-check` (machine-readable on purpose).
- The interface (`hs-ui`) has its own look (Catppuccin Mocha, same colours); its edit modes that prompt inside the screen (Disks tab)
  are to be replaced by the console wizards: the tab hands over to `hs pool <pool> add|replace|remove|convert`, which asks with these
  components, and reloads afterwards.
- Second pass (2026-10-11): table headers are Title case (`thead 'Setting' 'Value'`, acronyms such as MAC and CRC stay); `next_step` follows actions
  with an obvious follow-up (`config set` -> `hs rebuild`, `system rollback` -> `hs rebuild`), `fail_fix` carries the fix of a refusal
  (`hs update` fetch failure, `hs job follow` without a job, `hs reboot|shutdown` while busy -> `--force`), `elapsed_line` closes `system gc|rollback`
  and `docs build`.
