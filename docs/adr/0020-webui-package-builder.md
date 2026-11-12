# 0020: The web package builder: a form over the CLI validator, drafts kept apart, publish by pull request or archive

Status: Accepted (2026-11-10). Step 1 (check a manifest draft through the API, a form with live findings) is built; steps 2 and 3 are not.
Issue: hobnix/server#268 (part of #205). Builds on ADR 0006 (the `hs sys` contract is the API), ADR 0008 (packages, signed releases) and ADR 0014
(permissions); it does not repeat them. Numbers 0018 and 0019 are taken by records that are still open in their own pull requests.

## Context (checked 2026-11-08 on develop)
- A package is a folder with a `package.toml` in a package repository checkout (`recipes/<name>/`, `extensions/<name>/`). `hs pkg new` writes one
  that passes the checks (scripts/pkg_new.py); `hs pkg validate` and `pkg.py repo-check` check it (scripts/pkg.py `problems`, `repo_check`).
- Releases are signed tags made by the repository owner (`scripts/dev/release.sh`); a server installs only a verified tag into a read-only copy in
  `/var/lib/hs/packages/current` (ADR 0008).
- The web server runs `hs sys` words from an allowlist, with a document or one line on stdin (ADR 0006; the Docker editor's Test is the precedent for
  "check a text, answer with findings, change nothing").
- Issue #268 asks for guided creation and editing of recipes, extensions and capabilities from the browser, built on `hs create package` / `hs pkg validate`,
  with live validation, ending in a pull request or an exported archive, never writing into an installed package.

## Decision
1. **No logic of its own in the page.** The form only produces text (`web/src/pages/builder.js`). Every rule is the CLI validator's: the page sends the
   `package.toml` draft to `hs sys pkg plan check-draft`, which runs `pkg.py manifest_problems`, the same function `hs pkg validate` uses for installed
   manifests. A rule added there shows up in the browser without a web change.
2. **Checking is a plan, never a change.** `check-draft` exists only as `plan`; `start` refuses it. The draft is a document on stdin (at most 64 KiB, text,
   no NUL), never an argument; the answer is `finding<TAB>error|warn<TAB>where<TAB>text` lines, `where` being the manifest key or `-`.
3. **A draft is not a package yet.** The checks that need files (name equals folder, the script and its header lines, `capability.toml` beside an
   extension) cannot run on text alone. The answer says so with a `warn` finding; they run when the package is built (step 3) and in CI of the repository.
4. **Where drafts live (step 2).** In the browser (local storage) until a person asks to keep one; kept drafts go in `/var/lib/hs/package-drafts/<name>/`,
   owned by root, never below `/var/lib/hs/packages/current`, `packages/` or `capabilities/` of the checkout. Nothing in the builder writes into an installed
   package; an installed package is read-only and is changed by copying it into a draft.
5. **Editing (step 2).** Manifest by form (kinds, version, `requires_core`, audience, questions, permissions, web reads and changes), `run.sh`, `guide.md`
   and `i18n/de.tsv` in a code editor (the Docker editor's CodeMirror, with a lint of the header lines). Each save runs the check on the whole folder.
6. **Packaging (step 3).** A draft ends in one of two outputs, both made by `hs` commands: an archive (`hs pkg export <draft>`: a tar of the folder plus its
   `index.toml` entry, no signature) or a pull request (`hs pkg propose <draft> --repo <name>`: a branch in a checkout of a package repository the user
   configured, pushed with the user's own credentials, never with a key of the project).
7. **Signing stays with the owner.** The builder never signs. A release is the owner's signed `vX.Y.Z` tag (`release.sh`); an archive or pull request is
   just a proposal, and a server installs it only after a verified release (ADR 0008 rules 5 and 6). The page says so.
8. **Security.** Only a signed-in session with the CSRF token may send a draft; the answer contains nothing the person did not send plus the validator's
   fixed texts. A draft is data: it is parsed (`tomllib`), never executed; a script in a draft is only run after install, as any package.
   Permissions in a draft are declared, not enforced (ADR 0014); the page says that next to the field.

## Consequences
- The CLI and the page cannot drift apart: one validator, one test (tests/pkg-change.sh, tests/web-builder.sh).
- A draft that passes step 1 may still fail the file checks; the honest `warn` finding says so.
- Steps 2 and 3 need new `hs` commands with their own plan/start contract and rows in the registry before any page uses them.

## Open points
- Whether capabilities (ADR 0009, a third kind) get a template and form in step 2 or wait for hobnix/capabilities.
- Where the pull request step gets its credentials on a server without a GitHub account of the user (an archive is the fallback).
- Whether the page offers a diff against the installed version when a draft starts from an installed package.
