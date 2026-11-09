# 0025: Where translation lives: the `hs` commands, the web, or both

Status: Proposed
Issue: none yet. The owner decides. Nothing is built; this record investigates and recommends.

Numbers 0018 and 0023 are taken by open pull requests (interactive recipe runs, nested test harness).

## Context (counted 2026-11-09 on develop)

Two catalogs exist today.

**`hs` commands.** `scripts/lib/i18n.sh` loads `scripts/lib/i18n/<lang>.tsv` (English is the key, `\n` is a line break, `%s`/`%d` keep their
order) plus `capabilities/<name>/i18n/<lang>.tsv` of the packages that are on. The language comes from `hs config set language de`
(`/etc/hs/language`) or `HS_LANG`. `ui.sh` functions (`ok`, `note`, `warn`, `fail`, `step`, `ask`, ...), `say`, `die` and `t '<format>' args` look
the text up; a text without a line prints in English.

| Fact | Number |
|---|---|
| Entries in `de.tsv` | 2347 (2349 lines) |
| Shell scripts under `scripts/` and `capabilities/` | 223 |
| Call sites (lines starting with a ui function, plus `t '...'`) | about 1460 plus about 1140 |
| Command descriptions (`# help.de:`), a second German source | 163 lines in 162 scripts |
| Scripts forced to English for the web (`HS_LANG=en` in `*-change.sh` and similar) | 23 |
| Tests that run with `HS_LANG=de` | 9 |

`tests/i18n.sh` fails on a missing text (a script of the `CORE` list prints a key with no line), a duplicate key, a differing placeholder count and an
unused entry, and a command without `# help.de:`. `.gitattributes` sets `merge=union` on `de.tsv` so two PRs that both append do not stop each
other; the price is the duplicate keys that the test then reports.

**Web.** `web/src/i18n.js` is one object `de` with 223 keys, read by `tr('English')` in 16 of 167 Svelte/JS files (114 calls). English is the key
here too; a missing key stays English. The language is a browser choice (`lang.svelte.js`), first visit from `navigator.language`, with the server
setting `language` as fallback. The page bodies of older pages are still English only; newer pages (live state, ISO library, Docker wizard,
releases, storage incident) are translated. The web already runs `hs` with `HS_PLAIN=1 HS_LANG=en` and reads machine-readable lines
(ADR 0006), so it shows an `hs` sentence only where the API passes it through (error lines, job logs, `sys jobs` output).

**How much it costs.** In the last 300 first-parent commits on develop (28 Oct to 9 Nov 2026, the whole visible history) 54 touched `de.tsv`
(18%) and added 3516 lines. Without the one initial bulk commit (2698) that is 818 lines over 53 commits, mean about 15, median 5. Every new
user-visible sentence in a script needs a line there, and every one in the web a key in `i18n.js`: the same sentence is often written twice,
once in each file, in two shapes (`%s` and `{ref}`). The union merge removes most textual conflicts but not the work: a PR that adds a text
must also add the German, and a later PR can lose a line when a union merge goes wrong (the duplicate test exists because it happened).
The git history here is too short to count real conflict events; counting them from GitHub (PRs whose "resolve conflicts" commit touches
`de.tsv`) is an open task (question 1).

## What depends on translated `hs` output

1. **Machine-readable lines.** Lists the web or a script parses (`--list-disks`, `--json`, record files) are never translated by rule
   (`i18n.sh` header, tested in `tests/i18n.sh`). Dropping translation changes nothing for them.
2. **The web.** Runs with `HS_LANG=en`. The only effect is the sentences it passes through: job logs and error lines are English today even in a German
   interface. These are the real gap, and neither keeping nor dropping `de.tsv` fixes them.
3. **Tests.** 9 tests set `HS_LANG=de` and assert German text; `tests/i18n.sh` itself (about 80 lines plus `scripts/dev/i18n-keys.py`) exists for the
   catalog. All other tests assert English (they run without a language).
4. **Docs.** Guides are English only (`docs/GUIDE-TEMPLATE.md`); `docs/install.md` lists `language` as a first-run setting and `hs first-run` asks
   for it. `docs/Entwicklungsnotizen.md` and `docs/CLI-DESIGN.md` mention German messages. `hs help` shows `# help.de:` in German.
5. **People.** The unknown part: whoever runs `hs` on a German server and relies on German text. The owner is one; nobody else is known (question 2).
   The installer wizard, `hs first-run` and the motd are the most visible surface.
6. **Packages.** `capabilities/<name>/i18n/<lang>.tsv` and the `i18n.sh` API are part of the public core contract (ADR 0008, rule 4:
   `i18n.sh` carries an `api-level`). Removing translation is a deprecation, not a deletion.
7. **ADR 0018.** The web translates an interactive question by its key, so a recipe's `ask_q` already needs a stable key beside its English text.

## Options

### A. Keep both (status quo)

Cost stays as measured: two catalogs, an append to `de.tsv` per PR, the duplicate-key and placeholder tests. Risk: the web and the CLI drift
(the same sentence differs), and the web still shows English `hs` lines. Benefit: nothing to migrate; a German CLI user keeps German.

### B. Web-only translation; `hs` prints English only

Delete `de.tsv`, `i18n.sh` lookup, `tests/i18n.sh` and the package `i18n/` directories; `t` and `_tr` become `printf`. `# help.de:` goes or stays as
data for the web docs only.

- Migration: (1) keep `_tr`/`t` as pass-through for one `api-level` with a deprecation (ADR 0008); (2) tell packages; (3) delete the catalog and the
  test; (4) rewrite the 9 `HS_LANG=de` tests; (5) remove the `language` first-run question or let it only set the web default; (6) keep
  `HS_LANG` accepted and ignored.
- Cost: a one-off removal; afterwards a PR touches only `i18n.js`. Removes about 2350 lines of data and about 80 lines of test.
- Risks: a German CLI user loses German (breaking, and the product is aimed at home users who may use German on the console, `hs first-run`,
  motd and the installer). Pass-through text in the web (job logs, errors) stays English with nothing to improve it. The web catalog grows to
  carry sentences that exist only because a script prints them.

### C. `hs` emits keys or structured output; the web translates

An `hs` command in "structured" mode (for example `--json`, or a record with `code` and `args`) gives `{ "code": "disk.full", "args": ["sda", 91] }`;
the web maps code to text with named placeholders. The terminal still prints English.

- Migration: choose the shape (a field on the existing job record and `hs` JSON error object, ADR 0004/0006, so no new channel); add the code
  beside the English text at each call site that matters to the web (`fail_code disk.full "text"`); the web falls back to the English text for a
  code it does not know. Convert call sites by use, not all 2600: start with those the web shows (errors, job steps, ADR 0018 questions).
- Cost: a code per translated sentence in two places (script and `i18n.js`), but only for web-visible sentences; the CLI German catalog can be
  dropped (as B) or kept frozen. Stable codes are a contract: renaming one breaks the German text.
- Risks: a second naming scheme to maintain; the machine line then must not carry the English text as its only meaning; a half-converted
  tree shows both forms. Without B's removal it adds work instead of saving it.

### D. Keep the CLI catalog, generate the web catalog from it (or the reverse)

One source (`de.tsv`) and a build step that emits the part the web needs. Fixes drift, not the per-PR append, and the web wants named placeholders.
Not recommended on its own.

### E. A smaller CLI catalog

Translate only the entry points a person meets once or rarely (installer wizard, `hs first-run`, motd, `hs help`, the destructive confirmations);
everything else prints English. Cuts `de.tsv` to perhaps a few hundred lines (estimate, not counted) and keeps German where it matters most.

## Recommendation

Do **B in two steps, with C only where the web needs it**:

1. Freeze `de.tsv` now (no new entries unless a text is in the E list above) and make the test report instead of fail for texts outside it. This stops
   the per-PR append at once and costs nothing to undo.
2. Decide with the owner (questions 2 and 3) whether the E list is kept as the only CLI German; if not, remove `i18n.sh` lookup under an `api-level` deprecation.
3. For sentences the web passes through, add a `code` to the job/error record case by case (C), starting with ADR 0018 questions. Do not convert call sites the web never shows.

Reason: the measured cost is the double entry on every PR, while the only users known to read German `hs` text are the owner and the first-run
surface. The web is where non-expert users live and where a German text is needed. If the owner knows German CLI users, choose E instead of full B.

## Open questions for the owner

1. Is the cost the conflicts or the double work? Should I count conflict events from GitHub (PR history) before deciding?
2. Who reads German `hs` output today (you only, other testers, installed servers)? Is the console experience (installer, `hs first-run`, motd, `hs help`)
   a German promise?
3. Full removal (B) or the small kept list (E)?
4. May `i18n.sh` (`t`, `say`, `_tr`) stay as a no-op for one `api-level` for packages?
5. Should `# help.de:` stay, move to the web docs, or go?
6. Should job logs and errors shown in the web be translated at all, or is English acceptable there? (This decides whether C is needed.)
7. Is a stable message code per web-visible sentence acceptable as an API contract (renames need a deprecation)?
