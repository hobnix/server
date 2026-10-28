# Design reference (not shipped)

Prototype pages from Claude Design, 2026-10-27, unpacked from the exported bundle. Read-only reference for the redesign of the web interface
. They are a spec, not production code: rebuild them in Svelte.

- HANDOFF.md: the designer's handoff (tokens, components, states, pages, decisions, open items). Start here.
- Main.dc.html: the whole app (routed by the tree), all pages and states; `genSpec` is the data-driven generic page.
- Login.dc.html, Components.dc.html (dark and light), German.dc.html (long-text check).
- FilesStates.dc.html and PhoneFiles.dc.html (2026-10-28): the file manager (Storage > Files): static states, drag and drop, the tray, and the phone layout. The page itself is in Main.dc.html (tweak `fm`). Behaviour: docs/PLAN-file-manager.md and the "Files" section of HANDOFF.md.
- The three phone boards are copies of Main with other defaults and are not kept.

Ignore the runtime layer ({{ }} holes, sc-if / sc-for, DCLogic). The CSS, markup and sample data are the spec. The fonts are Geist (SIL OFL).
The halftone is decided in , not by the prototype's 3x3 crosses.
