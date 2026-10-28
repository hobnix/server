# docs (the guides inside the web interface)

The guides (docs/*.md, German) and the plans (English) plus a command reference made from `scripts/lib/registry.tsv` are a page of the
web interface: **Docs** (`/docs`, `/docs/<lang>/<slug>`). It replaces the recipe `docs` (a container with lighttpd and Docsify, removed
2026-10-23). The page works only with `webUi = true`; without it `hs help` is the documentation.

- On = `webUi = true` and `webDocs` not false (configuration.nix adds `docs` to /etc/hs/capabilities). The server answers `/api/docs/*`
  only while it is on (404 otherwise) and only to a signed-in user.
- Build: `hs docs build` (scripts/docs-build.sh) copies the guides to `/var/lib/hs/docs-site/en/<slug>.md`, makes the generated pages
  (`commands`, `start`) and `index.json` (scripts/lib/docs-index.py: the groups of docs/categories.tsv,
  the titles, the original file names so links between guides work). `hs update` / `hs rebuild` run it while the capability is on.
- API (scripts/web-serve.py, `_docs`): `index` (index.json), `page/<lang>/<slug>` (Markdown), `search?q=&lang=` (title, headings, text; at most 25 hits).
  Names are checked (`DOCS_SLUG`), the real path must stay inside the docs folder.
- Rendering: web/src/docs/markdown.js is our own small renderer, no dependency. Everything that is not Markdown syntax is escaped, links are
  http(s)/mailto or a guide (looked up in index.json by file name or slug), nothing else becomes a link. Raw HTML in a guide is shown as text,
  so a new guide must not use tags.
- A new file in docs/ is a page: list it in docs/categories.tsv and docs/README.md (tests/docs.sh). Guides are English and follow docs/GUIDE-TEMPLATE.md; contributor documents (PLAN-*, CLI-DESIGN, Entwicklungsnotizen, GUIDE-TEMPLATE) do not. A package's guide is `guide.md` in its folder (packages/<name>/, capabilities/<name>/, or what `hs pkg install` put under /var/lib/hs/packages/current/<name>/): docs-build.sh adds it under Apps (recipe) or Extensions.
- Recipes end with `$(docs_hint <slug>)` (scripts/recipes/_lib.sh): it names the guide in the web interface.
- Tests: tests/docs.sh (build, index), tests/web-docs.sh (API), tests/web-docs-markdown.sh (renderer, runs every guide through it).
