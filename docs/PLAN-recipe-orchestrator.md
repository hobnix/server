# Recipe orchestrator: the contract (ADR 0018 stage 3)

Status: built in hobnix/server (pull request A, backend). The web side (pull request B) follows this page. **Not tested on hardware yet.**
Decision record: docs/adr/0018-interactive-recipe-runs.md. This page is the exact contract between the backend and the web interface; where the two
differ, the ADR holds the reasons and this page holds the shapes.

## What the web does

1. Starts the run: `POST /api/start` with area `recipes`, args `["<recipe>", "run", "--interactive", ("--name", "<ct>")?, ("--set", "KEY=value")*]`.
   Nothing has to be answered up front; every `--set` is still validated. No secret goes on stdin here. The server adds `--by <user> --role <role>`
   (the client never sends them). Answer: `status started`, `unit`, `job` (the id of the orchestration record).
2. Follows the job: `GET /api/events` (`changed` on the jobs topic; the kinds `job.waiting` and `job.resumed` are new there) and `GET /api/sys/jobs/record/<job>`
   (a read; JSON, ADR 0004). When `state` is `waiting`, `waiting` holds the pending question:

   ```json
   {"seq": 3, "key": "PORT", "label": "Which port", "kind": "text|secret|choice", "default": "8080",
    "pattern": "[0-9]+", "choices": ["a","b"], "error": "That value does not fit here.", "attempt": 2, "asked": "2026-11-09T12:00:00Z"}
   ```
   `default` is null for a secret, `pattern` and `choices` are null when absent, `error` is null on the first try. `attempt` counts from 1; after 10 refused
   answers the step fails (`error.category = input_rejected`). The orchestration's `step {n, of, text}` is the phase it is in. `GET .../jobs/children/<job>`
   lists the sub-jobs (tsv, the columns of `jobs records`). A job that ended `cancelled` with `error.category = input_timeout` was not answered in time.
3. Sends the answer: `POST /api/start` with area `jobs`, args `["answer", "<job>", "--seq", "<seq>", "--key", "<key>"]` and ONE line in `stdin` (the value; a
   secret too; the server never logs it). The server adds `--by`/`--role`. Reply is the usual change reply: `status done` (stored), `stale` (not the
   pending question any more: just read the record again), `refused` (not the initiator or an admin, or the value does not fit a choice / has a control
   character / is empty for a secret; `reason` is plain English). An empty line for a `text` question means "take the default".
   The step's own check is the only judge of the *meaning* of a value: a refused value comes back as the same `key` with a new `seq`, `attempt + 1` and `error`.
4. Translates by key: the question id is `<recipe>.<key>`, a refusal text is shown through its text key; the English `label`/`error` of the record are the
   fallback. Plain text only, never HTML (ADR 0018 rule 16).

## Who may answer

Only the initiator of the job (`initiator` of the record = the `--by` of the start) or the role `admin`. Today every signed-in person is an administrator
(roles, ADR 0012, are not built: the server sends `--role admin`), so the check is in place and not yet restrictive in the web. A call without `--by` (root on
the server) is trusted like every `hs` command. Every answer writes one audit event with actor, role and key, never the value.

## Commands (all `hs sys`, ADR 0004 shapes, only additions)

| Row | Role (ADR 0012) | What |
| --- | --- | --- |
| `sys recipes start <recipe> run --interactive` | app-manager | new flag of the existing row; prints `job` in addition |
| `sys jobs answer <id> --seq N --key K` | app-manager + initiator or admin | answer on stdin; `status done\|stale\|refused`, `reason` |
| `sys jobs start answer <id> ...` | same | the way the web server reaches the row above (plan/start) |
| `sys jobs record <id>` (existing) | viewer | JSON, `waiting` as above |
| `sys jobs children <id>` (existing) | viewer | the sub-jobs |

## The protocol behind it (for recipe authors)

`ask_q <key> <kind> <label> [default] [pattern] [choices]` (scripts/lib/ask.sh, sourced by recipes/_lib.sh) prints the answer. Order: an answer given up front
(`RECIPE_<KEY>`, the secret file) wins; else `HS_ASK_DIR` set: ask through files and wait; else a terminal: the same `ask`, `ask_secret`, `choose` of ui.sh as
before; else the default. A retry after a refusal: `ASK_ERROR="plain English, no value" ASK_ATTEMPT=$n ask_q ...`. A secret is never in argv, the environment, the
record, an event or the journal: it is a 0600 file `$HS_ASK_DIR/a/<seq>` (tmpfs) that `ask_q` reads once and deletes. `setting` and the UniFi fixed-address loop
in recipes/_lib.sh use it (key `FIXED_IP`); every other `read`/`ask` of a recipe is converted one recipe at a time (ADR 0018, conversion order).
A step inside a container: `ask_q_exec <ct> <key> <kind> <label> ... -- <command>` asks on the host and hands the answer to the command's stdin
(`incus exec`); the container never sees `HS_ASK_DIR`. Folder: `$HS_RUN_DIR/ask/<orchestration id>/{q,a}` (default /run/hs, root, 0700). Sequence numbers are
never reused within an orchestration.

## The orchestrator

`scripts/recipe-orchestrate.sh <recipe> [--name <ct>]` is the unit of the orchestration job (`kind: orchestration`). It runs the recipe as sub-jobs (`kind: step`,
`parent`): one named `run`, or one per word of a `# phases: install configure start` header of the recipe (each reaches the recipe as `RECIPE_PHASE`). While a
step waits it sets `waiting` in its own record (`hs_job_record wait`, event `job.waiting` with key and kind only), sends one push message through notify.sh per
question (recipe name and label, never a value) and resumes the record when the step has its answer. No answer within `recipeQuestionHours` (default 24, a
setting) stops the sub-job, ends the orchestration `cancelled` with `error.category = input_timeout` and a message that says to run it again. `hs job stop` on the
orchestration stops the sub-job too. The folder is removed on every way out; the boot reconcile removes folders of runs that are not active.

## Not built / open

- Recipes are not converted yet (`# phases:` headers, `ask_q` instead of `read`); until then a run is one sub-job and asks only through `setting` and the fixed address.
- The Rust job-record writer does not know `error` (`hs_job_record error` falls back to the Python writer, like `uncancel`).
- No inotify: the step polls twice a second. Waiting jobs are not re-asked after a reboot (the folder is on tmpfs; the job is `interrupted`).
