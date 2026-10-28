# hobnix web interface – design handoff

Oct 27, 2026 · @hobnix

## Overview

This hands the hobnix web interface design to the implementing agent. The design files are a clickable prototype and a spec, not production code: rebuild the UI in the real frontend stack and take structure, tokens and page data from the files.

- **Files:** `Main.dc.html` (the whole app, routed by the tree), `Login.dc.html`, `Components.dc.html` (shared components, dark and light), `German.dc.html` (long-text check), `PhoneSummary`, `PhoneTree`, `PhoneNotif` (390 px), `canvas.json` (board layout).
- **Ignore the runtime layer:** the `{{ }}` holes, `sc-if`/`sc-for` tags and the `DCLogic` script only drive the prototype. The CSS, markup structure and sample data are the spec.
- **Tweaks in `Main`:** `theme` (dark, light), `view` (ok, loading, error, locked, empty, off, unreachable), `page` (every page), `tree` (closed, open on phone).
- **Source of truth for behaviour:** the original design brief for data, commands and the tree. All data in the design is sample data.
- **Not rendered by the designer:** the author could not view renders. Check every page visually, light and dark, desktop and phone.

## Halftone background: still in discussion

The halftone treatment (pixel-cross patterns with a slowly drifting glow, used on the Summary node card, the login brand panel and the dialog header) is **not final**. the author will explain how it should be implemented in a separate conversation with the local instance.

- Until then, treat the halftone as a placeholder: leave a clearly marked slot where it appears, and do not spend time polishing the effect.
- Fixed so far: it is made of pixel-based crosses (a 3 by 3 pattern with the X shape), uses only the accent colour and lighter or darker variations of it, and never appears inside buttons.
- Where it appears in the prototype: `.ht` blocks (Summary node card, dialog header) and `.hart` (login brand panel). The rest of the design does not depend on it.

## Design tokens and visual rules

Tokens live as CSS variables on `.t-dark` and `.t-light` at the top of `Main.dc.html` (same values in `Components.dc.html`). Fonts are Geist and Geist Mono.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `--bg` | oklch(0.15 0.012 285) | oklch(0.972 0.005 285) | page background under the hairline grid |
| `--panel`, `--panel-2`, `--panel-3` | 0.19, 0.225, 0.27 lightness | 1, 0.967, 0.93 lightness | cards, inputs, tracks and hover |
| `--line`, `--line-2` | white at 8 % and 17 % | ink at 10 % and 20 % | borders, dividers |
| `--fg`, `--fg-2`, `--fg-3` | 0.95, 0.79, 0.68 lightness | 0.2, 0.4, 0.49 lightness | text levels |
| `--accent` | #9184d9 | #9184d9 | selection and brand only |
| `--accent-ink` | oklch(0.8 0.1 295) | oklch(0.45 0.15 295) | accent text and icons |
| `--h1` to `--h4` | accent variations | accent variations | decorative, tabs underline, halftone |
| `--ok` | oklch(0.76 0.16 155) | oklch(0.66 0.16 155) | healthy |
| `--warn` | oklch(0.82 0.15 82) | oklch(0.78 0.16 80) | warning, locked, almost full |
| `--bad` | oklch(0.68 0.2 25) | oklch(0.6 0.21 25) | real failure, destructive |
| `--info` | oklch(0.74 0.12 245) | oklch(0.58 0.15 250) | in progress, informational |
| `--off` | oklch(0.5 0.01 285) | oklch(0.72 0.01 285) | switched off, unavailable |
| `--r` | 0 | 0 | corner radius: hard edges |

Rules agreed during review:

- **Hard edges everywhere.** Radius comes from `--r` (0). The only exception is the round icon tile on empty states.
- **Colour follows context.** Green is healthy, amber is a warning or locked, red is a real failure, blue is in progress or informational. A locked state is amber, never red. Accent is only for selection and brand, never for status.
- **Status is never colour alone.** A status dot is always paired with a word.
- **Usage bars** are segmented (4 px segments, 2 px gaps), green by default and amber above 90 %. In a selected table row the bar track switches to a neutral overlay so it stays readable.
- **Background:** a faint 24 px hairline grid with crosshair corner marks on cards (`.xh`).
- **Topbar:** one solid line at the bottom, the same as the bottom drawer top.
- **Scrollbars:** custom thin scrollbars; scroll areas reserve the gutter (`scrollbar-gutter: stable`) so content does not shift.
- **Primary button:** flat accent colour, no gradient or halftone. Danger button: flat red. Neutral inline button for the unlock field.

## Shared components

Build each once and reuse it. `Components.dc.html` shows them in dark and light.

| Component | What it is | Used on |
| --- | --- | --- |
| Status dot | 8 px dot, states ok, warn, bad, info, off; always with a word | everywhere |
| UsageBar | segmented bar, amber above 90 %, fixed width variant in tables | Summary, Pools, Backup, Hardware |
| Tree row | indent guides, caret, icon, label, chip, count, then one right-hand slot for lock or status dot; dimmed when locked | the tree |
| Table | header row, optional clickable rows with accent marker when selected, optional columns hidden on phone | all list pages |
| Side drawer | header (name, chip, state, close), tabs, key-value cells, rows, action buttons; full screen on phone | Pools, Disks, Shares, Instances, Users, Groups, extensions |
| Plan dialog | steps marked +, \~ or minus, note, Cancel and run; danger variant with red stripe and typed-name confirmation | every action |
| Unlock form | one passphrase field with the neutral Unlock button inside it | Summary, Encryption, locked-page banner |
| Banner | amber, red, blue or green, with optional action | states, Notifications |
| Combobox | one custom trigger plus a hard-edged popover (no native select); closes on Esc, outside click or pick | Notifications, forms |
| Switch and checkbox | light outline switch with a small square thumb; checkbox button with check; disabled cells show their reason | Notifications, Backup, Settings |
| Buttons | primary (accent), default, small, ghost, danger | everywhere |
| Chips and pills | small mono labels; pills mark "outside" or "this server" | tree, tables, Notifications |
| Empty state | round icon, one sentence, the one action | any list |
| Skeleton | grey blocks while loading | all pages |

## Shell, patterns and states

**Shell.** Topbar (logo, node switcher, search, data age with refresh, theme toggle, user), tree on the left with servers as roots, content on the right, bottom drawer with Jobs and Logs that can collapse. The local node is expanded first; remote nodes are collapsed with a status dot.

**Pattern for lists.** Table, then a side drawer for the selected row, then plan dialogs for actions. Actions never run directly: they open a plan listing each step, and the result appears in the Jobs drawer. Destructive plans need the object name typed.

**States every page handles** (use the `view` tweak to see them):

- **Loading:** skeleton blocks.
- **Empty:** one sentence and the one action that creates the first object (never an empty table).
- **Error:** amber banner with Try again; the old data stays visible with its age.
- **Storage locked:** amber banner with the unlock form, page data not read, tree entries dimmed with a lock.
- **Part switched off:** explanation with an info-coloured link to Settings; the tree entry is hidden when the part is off.
- **Node unreachable:** red banner with the likely reason and Try again, the last data greyed, no actions.

**Phone (up to 860 px).** The tree becomes a slide-in drawer, optional table columns are hidden, detail drawers go full screen, and the Notifications matrix turns into stacked channel cards with labelled rows.

## Pages

| Page | Notes for implementation |
| --- | --- |
| Login | Local admin or Samba user (domain field HOBNIX); show/hide password; DE/EN switch; locked state disables the Samba tab. Non-admins have no access to the interface. |
| Summary | Node card (uptime, load, memory, GPU, UPS), status lines that each open their owner page, one usage bar per pool, shortcuts that open plans. Locked: the unlock form replaces the pool bars. |
| Health | Problems grouped by storage, backup, system, network, with severity, link to object, since, channels told, acknowledge and undo. Actions: run check, resume paused jobs. |
| Pools, Disks, Shares | Table plus drawer. Pools: members, scrub state, add, replace, convert, close, remove. Disks: filter tabs, SMART history, tests, wipe. Shares: Permissions, Snapshots, History, Kept folders. The backup switch is not here. |
| Backup | Backup disk, off-site copy, one include list with switches (the only place), restore points, find a file, verify, restore drill. |
| Notifications | Matrix of channels by Alarm, Status, Heartbeat, Digest; per channel minimum priority, quiet hours behaviour, last result, send test. Warning when no outside channel carries alarms. Secrets typed once, never shown. |
| Nodes | Table of servers, add form, the key line a relative must add. |
| Encryption, Vault | Locked is a normal state here. Vault shows names and users of secrets, never values. |
| Instances, Apps, Services | Instances: drawer with Storage, Snapshots, Logs, Route. Apps: recipes with install plan. Services: public and private routes. |
| Network | Tabs: Overview, DNS, Ports, Router, Remote shares. |
| Groups, Users, Certificates | Editing here; the share-access matrix is read only. Certificates also feed Expiry dates. |
| Expiry, Hardware, Diagnostics, Setup, Docs, Settings | Settings holds part switches, extension switches and a pointer to Nodes. |
| Extensions | Generic page (Game streaming, Posters) built from the standard table, drawer and plan dialog. |
| Remote nodes | vps-edge: Mail entry, Ports, Outside watcher, Certificate, Tailscale, Settings. cousin-nas: read-only summaries. |

Most pages besides the first group are built from one data-driven pattern in `Main.dc.html` (`genSpec`): a page is a title, optional tabs, and blocks (table, key-value, cards, text, empty). Implement it as one reusable page renderer, not as separate hand-built screens.

## Decisions from review

- **Access:** non-admins have no access to the interface. There is no reduced UI for Samba users.
- **Kept folders:** the folders of deleted shares. Deleting a share never erases data; the folder is kept as `<share>.deleted-<date>`. The tab lists them with size and offers Restore (bring it back as a share) and Purge (erase for good). Purge is destructive and goes through the plan dialog with the typed name. A rename moves the folder and keeps nothing behind.
- **Heartbeat per provider:** each provider declares which categories it can carry, and a disabled cell shows that provider's own reason. Email: sent every 15 minutes, not suited to email (it would flood a mailbox). Matrix: the outside watcher can only read an ntfy topic today. Home Assistant lamp: cannot show a heartbeat or digest. A future webhook (healthchecks.io, Uptime Kuma push) can carry the heartbeat, so its cell is enabled.
- **Warning rule:** if no enabled channel outside this server carries alarms, show a warning, because everything on the server is down while storage is locked.
- **Status colours:** setup progress and running jobs are blue (info); the storage bulk bar is green; locked is amber.
- **Order of remaining work:** phone layout and a German text check were requested; both have boards in the design.

## Open items

- [ ] **Halftone background:** implementation approach to be discussed by the author with the local instance (see above).
- [ ] **Combobox keyboard support:** arrow keys, type-ahead and focus return are not designed yet. Tab and Enter work.
- [ ] **German text:** `German.dc.html` shows long strings in real components, but nobody has reviewed the render yet. Check phone widths first, especially tab labels like "Wiederherstellungspunkte".
- [ ] **Icons:** the icons are placeholders; replace with the Phosphor set.
- [ ] **Phone boards:** they are copies of `Main.dc.html` with different defaults. In the real build this is one responsive app; the boards only show the phone layout.
- [ ] **Sample data:** every number, name and date is invented. Wire each page to the real reads from the brief.
- [ ] **Accessibility pass:** tables are div-based rows in the generic pages; use real table or grid semantics in the build.
