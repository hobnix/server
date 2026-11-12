# 0016: Package UI stays declarative; third-party code, if it ever comes, runs in a sandboxed iframe

Status: Accepted (2026-11-10)
Issue: hobnix/server#267 (epic #195). Related: ADR 0006 (API in front of CLI), ADR 0012 (roles and tokens), ADR 0014 (extension permissions).

This is a research record. Nothing was built; the iframe sketch in "If code is ever allowed" was not tried in a browser.

## Context (checked 2026-11-08 on develop)

- A package gets a page **as data**: `[web.page]` in its manifest, drawn by the one generic renderer web/src/shell/GenericPage.svelte
  (docs/PLAN-extensions.md "The page declaration"). Block types: `table`, `kv`, `cards`, `text`, `empty`, `gallery`; actions open the core's plan
  dialog; a package may name a form only from the closed list in pages/Extension.svelte ("a package cannot bring code").
- docs/PLAN-extensions.md "Security": "A package cannot add a page, a route, a header or a script to the browser." hs-web runs as root, and
  its allowlists (reads, changes, page blocks over declared reads) are the security boundary. `web-serve.py` drops a whole package declaration
  when a block reads something the package did not declare.
- The web interface is a Svelte app built with Vite (web/); the build needs Node, the server does **not** have Node, so the built assets ship
  in the Nix store. A package therefore cannot be compiled on the server: any package UI code would arrive prebuilt.
- The browser holds the user's session (cookie or API token, ADR 0012). Anything that runs in the dashboard's origin can call every API the
  logged-in role may call, read the DOM of core pages, and read the token if it is script-reachable.
- Issue #267 states the premise: custom elements and shadow DOM isolate **styles**, not scripts.

## What actually isolates

| Option | Isolates what | Does not isolate | Cost for Hobnix |
| --- | --- | --- | --- |
| **Shadow DOM / custom elements** | CSS scope, DOM query scope | everything else: same JS realm, same origin, same cookies; `document`, `fetch`, `localStorage` are reachable | none, but not a defence |
| **Error boundary per component** (Svelte `<svelte:boundary>`, or try/catch around mount) | a render or lifecycle exception does not blank the page | infinite loops, memory leaks, event-handler errors outside the boundary, deliberate misuse, any data access | small; good as UX hygiene, not as security |
| **Web worker** (message passing) | no DOM access; own thread, so a loop does not freeze the page; can be terminated | not UI: a worker cannot draw. A worker can still `fetch` same-origin APIs with the user's cookie unless a CSP stops it | fits compute or data shaping only |
| **Realms: ShadowRealm / SES (Hardened JavaScript)** | a second set of globals in the same thread; SES freezes the primordials and runs code in compartments | a second realm still shares the thread and, unless the host passes nothing, the powers handed in; ShadowRealm's TC39 stage has been uncertain (it was discussed for demotion to stage 2 in 2023) and SES is a shim at stage 1 | needs a bundler step and a shim in the core's JS; the web interface has no use for it today |
| **Sandboxed iframe (`sandbox="allow-scripts"`, no `allow-same-origin`) + postMessage** | a separate browsing context with an **opaque origin**: no access to the parent DOM, cookies, `localStorage` or same-origin `fetch` with credentials; own event loop under site isolation in current browsers | what the bridge passes through; CPU use inside the frame (a hog still drains a laptop battery) | a small bridge, sizing and theming messages; same-origin-with-scripts must never be set (it lets the frame remove its own sandbox) |
| **Declarative only** (no package code in the browser) | everything: there is no third-party code in the page | expressiveness | the core adds block types when a package needs one |

Sources for the platform behaviour: the `sandbox` attribute and opaque-origin rules are in the HTML Living Standard and described by the
[Permissions Policy sandbox note](https://github.com/w3c/webappsec-permissions-policy/blob/main/sandbox.md); the warning that `allow-scripts`
together with `allow-same-origin` lets a frame escape is the same note and [this validator explanation](https://rocketvalidator.com/html-validation/bad-value-x-for-attribute-sandbox-on-element-iframe-setting-both-allow-scripts-and-allow-same-origin-is-not-recommended-because-it-effectively-enables-an-embedded-page-to-break-out-of-all-sandboxing.md).
SES: [tc39/proposal-ses](https://github.com/tc39/proposal-ses), [ses on npm](https://npmjs.com/package/ses). ShadowRealm: [tc39/proposal-realms](https://github.com/tc39/proposal-realms).

## Decision

1. **v1 and v2: packages ship no code to the browser.** A package's UI is `[web.page]` data. When a package needs something the blocks cannot
   say (a chart, a map, a log tail), the answer is a new block type in the core renderer, reviewed with the core and drawn by core code over the
   package's declared reads. This follows PLAN-extensions "Security" and ADR 0014: the allowlist, not the renderer, is the boundary, and there
   is no third-party script to isolate. It also keeps the interface translatable, themed and accessible by construction.
2. **No package may ship its own component until a later record accepts rule 3 or its replacement.** This record is that gate (acceptance
   criterion of #267). Shadow DOM and error boundaries are **not** accepted as the isolation mechanism.
3. **If code is ever allowed, it runs in a sandboxed iframe and nowhere else.** The shape, so that the decision is not reopened later:
   - The frame is `<iframe sandbox="allow-scripts">`, never with `allow-same-origin`, `allow-top-navigation`, `allow-popups` or `allow-forms`.
     The attribute is set before the element is inserted.
   - The assets are served by `web-serve.py` from the package folder with the response header `Content-Security-Policy: sandbox allow-scripts;
     default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'none'` (exact list is an open point). The `sandbox`
     directive in the header protects even when someone opens the URL directly, outside the frame, and `connect-src 'none'` stops the frame
     from calling any API or sending data out. Its only channel is `postMessage`.
   - The parent side is **one fixed bridge in core code**. The frame sends `{type: "read", words}` or `{type: "plan", ...}`; the bridge passes it to
     the same declared reads and changes (`ext/<name>/...`) with the user's session, so the server-side allowlist and the role checks (ADR 0012)
     apply unchanged. The frame never holds a token. The bridge also takes size, theme and language messages from/to the frame.
   - Messages are validated against a schema; an opaque origin reads as `"null"`, so the bridge identifies the frame by the `MessageEvent.source`
     it created, not by `event.origin`.
   - The frame is mounted only while the package is on (like `[web.page]` today) and is destroyed on disable.
   - Packages that ship code must be signed and show it in the install and update prompt (ADR 0014 step 1: a `ui.code` permission, highlighted in the diff).
4. **Do not use Realms or SES for this.** They add a shim and a build step to the core and still share the dashboard's thread and origin.
5. **Web workers are acceptable later for compute only** (parse a large answer, draw into an `OffscreenCanvas` handed to a frame), under the
   same bridge; they are not a way to render a package UI.

## Consequences

- Easier: the security argument stays one sentence ("a package cannot put code in the browser"); no CSP, bridge or sizing work is needed now.
- Harder: a package author who wants a custom view must ask for a core block type, which is slower than shipping a component. Each new block
  type needs i18n, phone layout, tests (tests/web-ext-test.py checks that every plan of shipped pages is accepted by the changes).
- If rule 3 is ever used: the bridge becomes a new API surface to test and version, and the frame cannot share fonts or theme tokens except by messages or an explicit CSS file in its own CSP-allowed `style-src`.
- Follow-ups (only when the need appears): new block types are ordinary issues; the iframe bridge is a spec of its own, ADR 0017 or later.

## Open points

1. Which block types do the first non-pilot packages need? Collect them before the first third-party package, so rule 1 is tested against real demand.
2. Exact CSP for rule 3 (inline styles, fonts, WebAssembly: `script-src 'wasm-unsafe-eval'` would only be needed if ADR 0015 is revisited).
3. Should the frame be served from a different origin (a second port or hostname) as defence in depth, or is an opaque origin enough? A second
   origin complicates the "admin pages never public" rule and reverse-proxy routes (CLAUDE.md).
4. Phone layout and keyboard focus: a frame needs its own scroll and focus handling; accessibility of a frame's contents is the author's job
   and cannot be checked by the core.
5. Do secrets ever appear in a read's output? Live reads store output in Redis in clear text today (PLAN-extensions "Live reads"); a frame
   would see the same data as the table block would.
