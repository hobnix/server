# Public website

Plan for a public site (landing page, install guide, documentation, changelog, downloads) built from the Markdown in this repository. Issue #489, part of #207. This is a plan: no site, repository, domain or workflow exists yet, and nothing here was run. **Not tested on hardware yet.**

## Before you start
- The guides and how they are written: [GUIDE-TEMPLATE](GUIDE-TEMPLATE.md), the build is `hs docs build` (`scripts/docs-build.sh`).
- How a release is cut: [RELEASE-PROCESS](RELEASE-PROCESS.md); update channels: [PLAN-channels](PLAN-channels.md).
- The owner decisions at the end must be made before step 2 of the build order.

## Audience and pages

Three kinds of reader, in this order of importance:

| Reader | Wants | Page |
| --- | --- | --- |
| Someone who has not heard of Hobnix | What is it, for whom, what does it look like, is it safe | Landing |
| Someone who decided to try it | Hardware, the ISO, the first hour | Install, Download |
| A user who already runs it | The right guide, the command, what changed | Docs, Changelog |

Pages (all static, no login, no server code, no cookies, no tracking):

| Page | Content | Source |
| --- | --- | --- |
| Landing `/` | Positioning from #458, three or four pictures, links to Install and Docs | handwritten (`site/index.md`); pictures from the demo mode (#461) when it exists |
| Install `/install/` | The install guide, a short "what you need" box above it | `docs/install.md` |
| Download `/download/` | Newest stable release, ISO link, checksum, how to check the signature, beta list | generated from the GitHub Releases API at build time |
| Docs `/docs/` | The nine core guides, the command reference, the guides of apps and extensions | `docs/*.md`, `hs docs build` output |
| Changelog `/changelog/` | Release notes per version, then the entry list | `docs/RELEASE-NOTES-*.md`, `docs/changelog/*.toml` |
| Roadmap `/roadmap/` | Milestones and open work | `docs/roadmap.md` |
| Security `/security/` | How to report a problem, the threat model | `docs/THREAT-MODEL-web.md`, `SECURITY.md` |

The Contributing group of the Docs page (PLAN files, ADRs) is published as a second section "For contributors", unlisted from the landing page, because it is the same Markdown and costs nothing. A page that is only a working draft stays out (see "What is never public").

## How the docs are built from the same Markdown

Nothing is written twice. The sources stay in `docs/` and in the package repositories; the site is output only.

1. **Content.** CI runs `hs docs build --out <dir>` (already supported). It produces plain Markdown per page under `<dir>/en/` and `index.json` (groups, titles, order from `docs/categories.tsv`), including the generated command reference and the guides of packages. The same bytes the server shows on its Docs page. The core has no `packages/` folder: `docs-build.sh` reads package guides from `$repo/packages`, `$repo/capabilities` and `$HS_STATE_DIR/packages/current`. So the CI job checks out hobnix/recipes and hobnix/extensions at the pinned tags and copies them into a temporary `HS_STATE_DIR/packages/current/` (the layout `hs pkg` leaves), instead of an empty state directory. Nothing else from a state directory is used.
2. **Rendering.** A static site generator turns that Markdown into HTML. Candidates:

   | Option | For | Against |
   | --- | --- | --- |
   | **Zola** (one Rust binary, in nixpkgs) | No Node, fast, front matter is simple, search index built in, fits a Rust project | Templates are its own language; we write a theme once |
   | mdBook | Very small, built for books, search built in | One book shape: no landing page or download page without extra work |
   | Astro / Starlight, Docusaurus, VitePress | Nicest docs out of the box, versioning plugins | Node toolchain and lock file in a Nix project; a second dependency tree to keep patched |
   | A small own script (Python `markdown` + a template) | Zero new dependency; the web interface already renders the same Markdown | We own search, navigation, anchors, sitemap forever |

   Recommendation: **Zola**. A tiny adapter (`scripts/dev/site-build.sh`, to be written) reads `index.json`, writes `content/` with front matter (title, weight from the order) and runs `zola build`. Guides carry no front matter in the repository and must not get any (GUIDE-TEMPLATE stays valid); the adapter adds it. Relative links between guides (`[Storage](storage-and-disks.md)`) are rewritten by the adapter to site paths, and a check fails the build on a dead link.
3. **The dependency stays dev-only.** Zola is installed in the CI job only (from the pinned nixpkgs, `config/nixpkgs-pin.toml`, or a pinned release binary); the repository has no dev shell today, so a local build needs Zola on the PATH. It is not to the server system closure.
4. **Version switch.** The site shows the docs of one release, and says so in the header ("Documentation for Hobnix 0.2.0", from the tag the build ran on). Phase 1: only `/` = newest stable. Phase 2: `/v0.2/`, `/v0.3/`, plus `/next/` built from `develop`, with a drop-down in the header. `deploy-pages` replaces the whole site on every run, so each deploy rebuilds every listed version from its tag (the build is cheap), or restores the older versions from the artifact of the last deploy; the adapter must do one of the two, never publish only the newest. The channels of [PLAN-channels](PLAN-channels.md) map directly: stable → `/`, beta → `/next/` for the milestone branch only when a beta tag exists, edge → `/next/` from `develop`.
5. **Where Markdown is not enough.** The landing page and the download page are handwritten templates in a `site/` folder of the core repository, so a change to the docs and a change to the landing page review in the same pull request.

## What is never public

The site is built from files that are public already (the repositories are public), but the build must not make private things easier to find, and must never run against a real server.

- **Admin pages and server state.** The site contains no screenshot or text of a real server's address, domain, user, share, key or log. Pictures come from the demo mode (#461) or a throw-away VM; the docs examples already use `example.com` and `192.168.1.x` (GUIDE-TEMPLATE rule 4). A CI check rejects the build if a page contains a private IP outside `192.168.1.x` (the `10.10.95.x` examples in PLAN-docker-instances and PLAN-modular-core are changed or allow-listed first), an e-mail address other than the project's, or a string that looks like a token (the same patterns as the secret scan).
- **No generated server files.** `hs docs build` is run with `HS_STATE_DIR` pointing to an empty temporary directory, so nothing from `/var/lib/hs` (installed package state, verified dates of a real server) can leak into the output.
- **Secrets.** The publishing workflow holds no secret except the one GitHub gives it for Pages (OIDC, no stored token). The docs hint to the web interface, the Incus/Zoraxy/Arcane/Grafana/Tdarr admin pages and the guide "Web interface" only describe them; the site never links to a running instance, and it carries no demo that talks to a live server. The rule "admin pages are never public" (CLAUDE.md, `ADMIN_TARGETS` in `scripts/services.py`) applies to the site as well: nothing on it proxies to the home server.
- **Drafts.** Files in `docs/` that mention an unreleased threat finding (open items in [THREAT-MODEL-web](THREAT-MODEL-web.md)) are the owner's call before the first publish: either published as they are (the repository is public anyway) or left out of the site with an `exclude` list in the adapter. Open decision 6.
- **No tracking.** No analytics, no web fonts or scripts from a third party, no cookie banner needed. Fonts are served from the site.

## Hosting options

| Option | Cost | Custom domain | CI publish | Notes |
| --- | --- | --- | --- | --- |
| **GitHub Pages from the core repository** (`gh-pages` branch or the Pages "Actions" source) | 0 for a public repository | Yes, CNAME file + DNS, HTTPS by GitHub | `actions/deploy-pages` on a tag or a push to `develop` | Simplest. The site and the code share one repository, so a pull request can change both. Pages output is limited to 1 GB and 100 GB/month traffic, far above a docs site |
| **GitHub Pages in a separate repository** `hobnix/website` | 0 | Yes | A workflow in the core triggers the other one (`repository_dispatch`) or the website repo builds from a checkout of the core | Keeps `gh-pages` commits and Pages history out of the code repository; needs a deploy token or an app to dispatch between repositories: one more secret |
| Cloudflare Pages / Netlify | 0 on the free tier; limits on builds | Yes | Their Git integration, or `wrangler`/`netlify deploy` from CI | Preview URL per pull request is nice; adds an account, a vendor and a token. The free tier terms can change |
| Own server (a VPS or the Hobnix test machine) | VPS from about 4 EUR/month | Yes | `rsync` from CI over SSH | Full control, but a public machine to patch and an SSH key in CI. Not for a project that sells self-hosting without needing it |

**Recommendation: GitHub Pages from the core repository, built by Actions** (not from a branch, so no build output is ever committed). It costs nothing, the domain is a CNAME, nothing needs a new account, and a pull request builds the site without publishing it (the artifact is checked, not deployed). Move to a separate repository later only if the Pages history or workflow runs get in the way; the build script does not depend on where it runs. Preview per pull request is not available on plain Pages; the CI job uploads the built site as a workflow artifact so a reviewer can download it.

Action minutes: `ci.yml` runs on pull requests, on pushes to `develop` and the milestone branches, on tags and nightly (it once ran out of minutes), so the site job is small and path-filtered. The site build is one small job (Zola builds this size in seconds, `hs docs build` is a few seconds), and runs on: pull requests that change `docs/**`, `site/**` or `scripts/docs-build.sh` (build and checks, no deploy); a release tag (deploy `/` and `/vX.Y/`); a push to `develop` (deploy `/next/`).

## CI publish

A new workflow `.github/workflows/site.yml` (not written yet):

1. `build`: checkout core (+ recipes and extensions at the tags the core pins, `docs/PLAN-packages.md`), dev shell, `hs docs build --out out/docs` with an empty `HS_STATE_DIR`, adapter, `zola build`, checks (links, the public-leak scan above, `tests/docs.sh`), upload the artifact `site`.
2. `deploy` (needs `build`, only on a tag or `develop`): `actions/deploy-pages`, environment `github-pages`, permission `pages: write` and `id-token: write` for this job only.
3. The job is **not** part of `ci-ok`: a broken site build must not block a code release. It must not be a path-filtered required check (a required check that never reports blocks every other pull request): the workflow always starts on a pull request and its first step ends green when no relevant path changed, and the release workflow starts it with `gh workflow run site.yml --ref <tag>` (a push with the workflow token starts no workflow, as already seen in [RELEASE-PROCESS](RELEASE-PROCESS.md)).
4. `main`, `develop` rulesets do not change. Deploy permission needs the `github-pages` environment, with deployment branches limited to `develop`, `main` and `v*` tags.

## Release-process hookup

Add to the release steps of [RELEASE-PROCESS](RELEASE-PROCESS.md) once the workflow exists:

- `scripts/dev/release-gate.sh check` additionally requires that `docs/RELEASE-NOTES-X.Y.md` renders on the site (already required to exist) and that the site build for the release commit is green (a read of the check run, the same way `ci-ok` is read).
- The `release` workflow, after the tag is pushed and the GitHub release is created, starts `site.yml` on the tag. The download page reads the release it finds and lists the ISO, its `<iso>.sha256` file and the tag signature check. A beta tag is listed under "Beta" and never on the front of the page; stable is the newest non-prerelease.
- A hotfix tag rebuilds `/` the same way; there is no separate step.
- The owner checks the download link once after the first stable release (like step 4 of a release, "Check"): the ISO URL and checksum on the site equal the release's.
- Docs fixes between releases: a pull request into `develop` updates `/next/` only. `/` changes at a tag. A typo on the stable site then waits for the next tag unless the owner runs `site.yml` on the existing tag with a newer docs ref; this is open decision 7.

## Translations

The CLI and the docs are English only (ADR 0025 (`docs/adr/0025-translation-scope.md`): translation is the web interface's job). The site is English only: no `/de/`, no language switch, `lang="en"`. German strings of the repository (`Entwicklungsnotizen.md`, the German cheat sheet `hs cheatsheet`) are not published; `Entwicklungsnotizen` is left out of the site (notes in German, per-feature history, not user documentation). If translation ever starts, the site follows the CLI: a language folder per language in `categories.tsv` already exists (the first column), and Zola supports multilingual sites, so no change of structure is needed now.

## Check that it worked

For the plan: the owner reads the open decisions and answers them in #489. For the build, once it exists:

- `hs docs build --out <dir>` with an empty state directory gives the same pages as the Docs page of a server.
- The site builds from a clean checkout with one command (`bash scripts/dev/site-build.sh`).
- The link check and leak scan pass; the landing page and Install work with JavaScript off.
- The download page shows the newest stable ISO, its checksum and the signature check, and the numbers equal the GitHub release.

## Build order

1. This plan, answers to the owner decisions (#489).
2. Adapter and Zola theme with Docs and Install only, built in CI as an artifact, not published.
3. Landing, Download, Changelog, Roadmap pages; the leak scan and link check.
4. Publish workflow, custom domain, address in the README and the repository description.
5. `/next/` and the version switch.
6. Pictures from the demo mode (#461), when it exists; the landing page works without them first (text and one terminal-style image made from `hs` output).

## Owner decisions

Nothing below is decided; no repository, domain or account was created for this plan.

1. **Domain.** Which name, and who registers it? Options: the free `hobnix.github.io/server` (no cost, no DNS, but changes when the repository moves, and the project path is part of every link) or a registered domain (about 10 to 20 EUR a year for `.org`/`.dev`, DNS at the registrar or Cloudflare). A custom domain is much better for a project people are asked to install from; if one is chosen, register it before the first public link is shared, (GitHub redirects the old `github.io` address to the custom domain, but pick the final name early anyway).
2. **Hosting.** Confirm the recommendation (GitHub Pages from the core repository, built by Actions), or choose a separate `hobnix/website` repository.
3. **Name and branding.** Is "Hobnix" the public name, is there a logo, colours and one sentence of positioning (from #458)? The theme needs a logo (SVG) and two colours; without them it uses plain type and no logo.
4. **Site generator.** Confirm Zola, or prefer a Node-based generator (Starlight) for its look and versioning plugins at the price of a Node toolchain.
5. **Contributor material.** Publish the Contributing group (PLAN files, ADRs, threat model) or keep the site to users only.
6. **Open security findings.** Whether the published threat model may list unresolved findings (it is public in the repository already).
7. **Docs fixes on stable.** Rebuild `/` from `main` on every docs-only merge, or only at tags.
8. **Contact and reports.** The e-mail or issue form shown on the Security page, and whether the existing `SECURITY.md` is enough as it is.
9. **Analytics.** None (this plan), unless the owner wants a privacy-friendly counter later.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| The site build fails on a PR that only touches a guide | A relative link or a heading the adapter cannot map | Run `bash scripts/dev/site-build.sh` locally; the dead link is named |
| Pages shows the old release | The `site.yml` run on the tag did not start | Start it with `gh workflow run site.yml --ref <tag>` |
| The leak scan flags a guide | A real address or token in an example | Replace it with `example.com` or `192.168.1.x` |
| A page shows a server's own data | The build ran with a real state directory | The workflow must set an empty `HS_STATE_DIR`; the test checks it |

## Next
- [RELEASE-PROCESS](RELEASE-PROCESS.md): where the site build joins a release.
- [PLAN-channels](PLAN-channels.md): the channels the version switch follows.
- [GUIDE-TEMPLATE](GUIDE-TEMPLATE.md): the shape the published guides keep.
