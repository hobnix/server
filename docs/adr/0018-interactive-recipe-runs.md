# 0018: Interactive recipe runs through an orchestrator job

Status: Accepted (2026-11-09)
Issue: to be filed (none exists yet); the follow-ups are listed under Consequences. Builds on ADR 0004 (job record), 0005 (events), 0006 (API in front
of the CLI) and 0012 (roles); it extends 0004, it does not replace it.

"Verified" below means read in the code of this repository on origin/develop (2026-11-08). Everything in the Decision is a design and is
**not built and not tested**, on hardware or otherwise.

## Context

- The web dialog (`web/src/forms/ops/RunRecipe.svelte`) is a flat one-shot form. Its fields come from static `# ask:` header lines of the
  recipe (`scripts/recipe-asks.sh`, `hs sys recipes asks <recipe>`: key, label, kind `text|secret|choice:a,b`, default, pattern, `when`).
  It then calls `hs sys recipes start <recipe> run --set KEY=value`, with ONE secret on stdin (`scripts/recipe-change.sh`). The secret is written
  as a root-only file in a temporary folder under /run/hs, read by the recipe with `answer KEY` and removed when the job ends. The recipe runs
  as a background job (`hs_job`, `scripts/lib/job.sh`) with `HS_CALLER=ui|job` and no terminal. Verified.
- The CLI asks while it runs: `ask`, `ask_secret`, `choose`, `confirm` in `scripts/lib/ui.sh`, and `setting` / the fixed-address loop in
  `scripts/recipes/_lib.sh` (a question, a check, a reason on refusal, ask again). A job has no terminal, so `interactive()` is false and every
  such question silently takes the stored answer or the default. Verified.
- So the web can only ask what the author declared up front. A question that depends on an earlier result (a free address that UniFi refuses, a
  value the install itself produces, a retry after a rejected password) cannot be asked. A recipe that needs this declares `# input: terminal` and
  the dialog says "run `hs recipe <name>` in the terminal" (`recipe-change.sh` refuses it; `domain` is the one named in the code). How many of the
  recipes in hobnix/recipes (not in this repository) say `terminal` was **not verified**.
- Jobs: one JSON record per job (ADR 0004, `scripts/job-record.py`, same format from the Rust writer), states `queued|running|ok|failed|cancelled|
  interrupted`, a `step {n, of, text}`, a `cancel` request file, a reconcile at boot that turns a dead `running` into `interrupted`. Events
  `job.<state>` go to the event log (ADR 0005, `scripts/lib/event.sh`, kinds in `scripts/lib/event-kinds.tsv`). The web follows a job by
  `GET /api/sys/jobs/stream/<unit>` (the journal as server-sent events) and learns that something changed from `GET /api/events` (`changed`
  per topic). The record has no parent, no question and no way to take input from outside. Verified.
- A browser terminal already exists (`scripts/web_terminal.py`: pty in a transient unit as the local account, tmux session per user and target).
  It runs as that local account, with sudo, so it is a shell, not a role (see Alternatives).

The owner wants a wizard: the recipe runs in steps, each step says when it needs input, and the person answers in the web, even when the
question only exists because of what an earlier step found.

## Decision

Direction chosen by the owner: option 3, an orchestrator. The owner answered the open points on 2026-11-09; the answers are rules 3, 4, 11, 12, 12b, 14, 15 and 16. It is delivered in two stages (rule 12) so the web improves before the hard part exists.

### Job model

1. **A recipe started in interactive mode is an orchestration job.** `hs sys recipes start <recipe> run --interactive ...` starts one job
   (unit `hs-job-recipe-<name>-<HHMMSS>`, an ordinary record, `kind: "orchestration"`). It runs `scripts/recipe-orchestrate.sh`, which reads the
   steps of the recipe (rule 12, stage 3) and runs each as a **sub-job**: its own `hs_job`, its own unit and record, `parent: <orchestration id>`.
   A recipe that is not split into steps yet runs as ONE sub-job named `run`; the question protocol below works the same for it, which is why
   conversion can go recipe by recipe.
2. **Record fields, all optional and additive** (the record stays `version: 1`; readers ignore what they do not know, as in ADR 0010 rule 3):
   `parent` (id or null), `kind` (`orchestration` | `step` | null), `waiting` (null, or the pending question: `{seq, key, label, kind, default,
   pattern, choices, error, attempt, asked}`; never an answer, never a default for a secret). `step {n, of, text}` of the orchestration
   job is the step it is on.
3. **New state `waiting`** ("waiting for input"), not terminal. The orchestration job goes `running` -> `waiting` while a question is pending and back
   to `running` when it is answered; the sub-job that asked stays `running` (it is blocked in `ask_q`). `hs job` and the jobs page list it as
   active; `cancel` works from it; reconcile turns a `waiting` job whose unit is gone into `interrupted` like `running` (ADR 0004 rule 6).
   This **extends ADR 0004 rule 4** ("only these states"); the enum of `sys jobs records` gains `waiting`. **Decided by the owner: a real state, not a field.** The price: any consumer
   that switches on the state breaks on a value it does not know, so the jobs page, timers and `hs job` are updated with it.
4. **Events** (new kinds in `event-kinds.tsv`, regenerate docs/events.md): `job.waiting` (subject = orchestration id, payload `{key, kind}`,
   never a label that may contain a value, never an answer) and `job.resumed`. They give the web a `changed` on the jobs topic at once
   and the push channel something to notify on: a job that goes `waiting` sends one notification through `notify.sh` (owner decision; the text names the recipe and the question label, never a value).

### Question and answer protocol

5. **Where it lives.** A directory per orchestration `/run/hs/ask/<orchestration id>/` (root, mode 0700, tmpfs): `q/<seq>.json` and `a/<seq>`.
   It is passed to the orchestrator and every sub-job as `HS_ASK_DIR`. tmpfs is deliberate: a reboot discards pending questions and secrets,
   which matches "a reboot makes the job interrupted" (rule 9).
6. **Question.** A step calls `ask_q <key> <kind> <label> [default] [pattern] [choices]` (rule 10). Job mode writes `q/<seq>.json`
   atomically (temporary file, rename; `{"v":1,"seq":N,"id":<sub-job id>,"key":..,"label":..,"kind":"text|secret|choice","default":..,
   "pattern":..,"choices":[..],"error":..,"attempt":N}`) and waits. The orchestrator, which watches the directory, copies it into its own
   record as `waiting` (one pending question at a time; several sub-jobs asking at once are queued by `seq`) and emits `job.waiting`.
   The journal gets one human line (`waiting for: <label>`), not a structured one: stdout goes to journald, which is neither private nor
   reliable, so nothing machine-read travels there.
7. **Answer.** `hs sys jobs answer <id> --seq N --key K` with ONE line on stdin (like `unlock`; `stdin = "line"` in sys.toml). It checks that
   `seq` and `key` are the pending ones (else exit 1, status `stale`; a double submit is harmless), rejects control characters, a `choice` outside
   `choices`, and writes `a/<seq>` atomically with mode 0600. The waiting step reads it (inotify if present, else a half-second poll), **deletes the file at once**
   and goes on. Chosen over a FIFO: a FIFO blocks the writer until a reader exists, loses the answer if the reader restarts, and cannot be
   written by a plain shell test. An empty line means "take the default" for `text`; a `secret` has none.
8. **Validation and retries.** The step's own check is the only authority (the same code the CLI runs). On a refusal it calls `ask_q` again with
   the same key, `error` set to one plain English line and `attempt + 1`; the record's `waiting` shows it and the web shows it under the field
   (the browser translates known `error` codes, a free text stays English: rule 16). The error line must never contain the value. After 10 attempts
   the sub-job fails with `error.category = input_rejected` (the tty loop has no limit; a job that waits forever on a bad answer is worse).
   The answer API only checks what the step cannot misjudge: shape, `seq`, `key`, choices.

### One function for CLI and web

9. **The CLI keeps working unchanged.** `ask_q` (new `scripts/lib/ask.sh`) picks the mode in this order: (a) an answer given up front
   (`RECIPE_<KEY>` or the secret file: today's `answer`, so `--set` and stdin still win); (b) `HS_ASK_DIR` set: the job protocol above;
   (c) a terminal: it calls the existing `ask`, `ask_secret`, `choose` in ui.sh with the same words and output as today; (d) neither: the stored answer
   or the default, as today. `setting` and the loops in `_lib.sh` call `ask_q`; ui.sh is not changed. A test must show that tty-mode output
   of a migrated recipe is byte-identical before and after (to be written; not done).
10. **Secrets** (rule 7 of ADR 0004 and CLAUDE.md apply in full). The value is typed in the browser, sent in the JSON body of the POST,
    handed by the web server to `hs sys jobs answer` **on stdin only**, written to a 0600 file on tmpfs, read once by the step and deleted. It is never
    in argv, in the environment, in the record, in an event, in the journal, in a web server log (the server already logs no bodies; a test
    must prove it for this route), and `waiting` carries no default for it. The step passes it on the way the recipe already does for a secret
    (stdin or a 0600 file, never argv). Not covered, same as today: the page is plain HTTP on the home network and Tailscale (docs/PLAN-web-backend.md),
    and tmpfs can be swapped to disk on a host with swap (to check: whether the unit sets `MemorySwapMax=0`).

### API surface (web speaks to the orchestrator only)

11. **Three changes, no new mechanism.** `docs/api/sys.toml`, `registry.tsv`, `openapi.json` and `sys.gen.d.ts` are regenerated in the same commit
    (CLAUDE.md rules), and a new row needs a role (ADR 0012 rule 2):
    - `sys recipes start <recipe> run --interactive`: same answers as today, returns `unit` and `job` (the record id). Role `app-manager`.
    - `sys jobs answer <id> --seq N --key K` (stdin line): role `app-manager`, **and** the person must be the job's initiator or an `admin`
      (owner decision; anyone else gets 403 and nothing is written). Writes an audit line with key and role, never the value.
    - `sys jobs children <id>` (read, tsv, role `viewer`): the sub-jobs of an orchestration. A new row because the columns of `sys jobs records`
      are a contract; the `parent`, `kind`, `waiting` fields are additive in the JSON of `sys jobs record <id>`, which is what the web polls.
    The web watches `GET /api/events` (`changed` on the jobs topic), reads `jobs record <id>`, shows the question when `waiting` is set, and POSTs the
    answer. It never reads a sub-job and never needs a sub-job id; the existing `jobs/stream/<unit>` stays the log view of the orchestration unit
    and of each step the person opens. The step list for a progress view comes from `jobs children`.

### Timeouts, abandoned and interrupted jobs

12a. **The browser closes mid-run.** Nothing breaks: the job runs until the next question and then sits in `waiting`. The jobs page lists it
    ("waiting for input", with a button that opens the same question dialog from the record), so the person can come back from another browser.
12b. **A question times out** after 24 hours (owner decision; a setting to be added to config/schema.toml, so `schema-gen.py` and docs are involved):
    the orchestration is **cancelled cleanly**: it stops the sub-job at a safe point (`hs_job_cancelled`), ends `cancelled` with
    `error.category = input_timeout`, and the directory is removed. The message says "run it again".
12c. **Resume = run again.** Recipes are safe to run again (their header says so) and `setting` already stores non-secret answers, so a
    new run asks only what is still unknown, a secret again. No step-level resume or checkpoint file is built (a half-done step is not
    something to trust; the recipe's idempotence is the checkpoint). This rests on that idempotence **not verified for every recipe**; a recipe
    that is not idempotent must not be converted until it is.
12d. **Reboot:** units and `/run/hs/ask` are gone; reconcile marks `interrupted` (existing rule); nothing is re-run, nothing is asked at boot.
12e. **Cleanup:** the orchestrator removes its directory in a trap; reconcile and the daily housekeeping remove directories of ids that are not
    active. Sub-job records are kept and pruned with their parent (ADR 0004 rule 8 counts orchestrations, not steps, or eight steps per recipe
    would push real history out of the newest-200 window).

### Migration in three stages

12. Two stages, each its own PR series; no stage changes an existing `hs sys` line. **Stage 2 (plan-first dry run) is dropped** by the owner:
    the orchestrator makes it unnecessary, and a plan that guesses what a run will ask is worse than asking when it matters.
    1. **Static step wizard** (web only plus headers), first. Recipe headers gain `# step: ID|label` and `# help: ID|text`, and a trailing field `step` on
       `# ask:` lines (`recipe-change.sh` reads fields with `read k l t d p w _`, so a 7th field is ignored by it; `recipe-asks.sh` keeps its six
       output columns). A new row `sys recipes steps <recipe>` returns step id, label, help and the ask keys of each. The dialog shows steps
       one after another, a **plan preview** (the existing `recipes plan`) as the last page, then ONE job as today. Needs no orchestrator and
       no protocol; fixes layout, help text and ordering. The last `input` row gains the value `steps` only when stage 2 exists.
    2. **The orchestrator** (rules 1 to 11), second, starting with the question protocol in `_lib.sh` (the UniFi fixed address, which has a retry loop and
       is shared by many recipes), then recipes one by one.
    **Conversion order of the 'needs a terminal' recipes:** (a) anything whose only reason is a retry loop or a computed value; (b) recipes that need
    a secret typed twice or confirmed; (c) `domain` last: the Administrator password is typed into Samba's own prompt on a pty; `samba-tool` takes it
    in argv or interactively, and argv is forbidden for secrets, so converting it needs a way to feed Samba without argv (not verified that one
    exists). It may stay terminal-only, and that is an acceptable result. Per recipe: replace direct `read`/`ask` by `ask_q`, add `# step:` lines,
    run it in tty mode and in job mode against the fake answerer, change `# input: terminal` to `steps`, update docs and the changelog.

### Granularity, containers, translation

14. **Sub-jobs for big steps, logical steps inside them** (owner decision). Install, configure and start are sub-jobs (own unit, record, log,
    cancel point); the small steps inside one are `hs_job_step N OF TEXT` as today, not records. Retention counts orchestrations, rule 12e.
15. **A step inside a container** that needs an answer asks through the host: the code in the container does not get `HS_ASK_DIR`; the host-side
    part of the step (the one that runs `incus exec`) asks with `ask_q`, and passes the answer in by stdin or a 0600 file, never argv, as rule 10 says.
    Nothing in the container can see the host's ask directory.
16. **Translation** (owner decision). The web translates by question key (`<recipe>.<KEY>`, errors by code). A recipe ships English `label`
    and error text, which the web shows when it has no translation; a package may add `label.de` (and so on) beside `label`. Text only, never HTML.

### Tests without hardware

13. A fake answerer: `HS_ASK_SCRIPT=<file>` (test knob, like `HS_RECIPES_DIR`) holds `KEY=value` lines read in order, so a test gives a wrong value first and
    sees the retry; `HS_RUN_DIR` moves `/run/hs`. `tests/ask-protocol.sh` starts a step in the background, plays the answerer with
    `jobs answer`, and covers: text, choice, secret (and that the value is nowhere in the record, events or journal copy), stale `seq`, retry with
    error text, attempt limit, timeout (short knob), cancel while waiting, reconcile of a waiting job, directory cleanup. The orchestrator is tested with
    `HS_RECIPE` stand-in recipes as `recipe-change.sh` is today. The web side gets a component test with a mocked API (what test setup `web/`
    has for this was not checked). Real recipes and UniFi: "Not tested on hardware yet."

## Alternatives considered

- **Static wizard only (stage 1 alone).** Cheap, no new mechanism, no new attack surface. Cannot ask what depends on an earlier step, cannot
  retry on a refusal, keeps `terminal` recipes as they are. Right as the first step, not as the answer.
- **Plan-first only (the dropped stage).** Asks everything before running, which is also a safer UX for destructive work (decide, then act).
  But a decision that depends on a result of the run cannot be known before it, and a recipe needs refactoring to make its plan honest; a plan
  that guesses wrong is worse than a question mid-run.
- **Web terminal / pty for these recipes.** Exists today and covers every recipe including `domain` with no recipe change. Against it: it is a shell as
  the local account with sudo, so using it for an app install hands an `app-manager` a root shell, which defeats ADR 0012; it has no validation,
  no German, no wizard, and a password typed into it can remain in tmux scrollback. Kept as the fallback for what stays terminal-only (an admin-only action).
- **Long-poll or SSE per sub-job (the web talks to each sub-job).** Simpler server side (no relay, no orchestrator role in the protocol). The
  web must discover sub-jobs, hold a request per question, and a closed tab loses the pending question; `http.server` threads are held while
  waiting (verified it is a threaded `http.server`, load not measured). It also puts one API surface per step on the roles table.
- **`waiting` as a field, not a state.** Rejected by the owner (rule 3).
- **FIFO as the answer channel.** Rule 7 gives the reasons for a file.

## Consequences

- Easier: the web can ask what the CLI asks, at the moment it matters, with retries and validation messages; recipes lose most of their
  `terminal` fallback; one question function for both front ends; the jobs page shows a stuck job and a way back.
- Harder: ADR 0004's record, both writers (Python and Rust must learn `parent`, `kind`, `waiting`; an older binary falls back to Python as
  `hs_job_record` already does for `uncancel`), the states enum in consumers (jobs page, timers, `hs job`), the retention rule, the events
  catalogue, the roles table. A job can now sit for hours holding a half-set-up container (acceptable because of idempotence, rule 12c).
- A second place secrets pass through (the answer file), so rule 10 needs its tests before the first secret recipe moves.
- **Built (hobnix/server#387, groundwork only):** the record fields `parent`, `kind`, `waiting`, the state `waiting`, the writer commands `new --parent --kind`, `wait`, `resume` (Python and Rust, same JSON), reconcile, cancel and retention for `waiting`, the events `job.waiting` / `job.resumed`, and the read row `sys jobs children <id>` (role `viewer`). Not built: `ask_q`, `jobs answer`, the orchestrator, the notification. A `wait` is accepted only from `running` or `waiting`. `uncancel` of a cancelled waiting job puts it back to `running` without its question (the orchestrator asks again). Not tested on hardware yet.
- **Built (stage 3, hobnix/server pull request A):** `ask_q` and `ask-q.py` (the file protocol), `recipe-orchestrate.sh`, `recipes start ... --interactive`, `jobs answer`, the 24 h timeout (setting `recipeQuestionHours`), the push message, the host relay `ask_q_exec`, `setting` and the UniFi address loop on `ask_q`. The exact shapes: docs/PLAN-recipe-orchestrator.md. Not built: converting recipes, Rust `error`, inotify. Not tested on hardware yet.
- Follow-up issues: stage 1 (headers, `recipes steps`, wizard dialog); `ask_q` and its tests; record fields and Rust parity;
  `job.waiting` events; `jobs answer`/`children` rows with roles; orchestrator; per-recipe conversion list; `config` key for the timeout; docs
  (GUIDE and German texts for every new web string; the repo's i18n rules apply to the dialog, not to this record).

## Open points

- **Where translation lives (owner's idea, not decided, not designed here):** possibly drop the translations from `hs` commands and translate
  only in the web. That touches scripts/lib/i18n.sh, the i18n tests and every command; it needs its own investigation and record. Until then
  rule 16 applies.
- Not tested on hardware yet.
