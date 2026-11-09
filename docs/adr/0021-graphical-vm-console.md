# 0021: Graphical VM console: Incus's own VGA console (SPICE) relayed through the web interface

Status: Proposed. The server side (ticket, relay, limits) is built and tested with a fake Incus; it is NOT VERIFIED against a real Incus VM. The picture in the browser is not built (rule 6).
Issue: hobnix/server#261 (part of #199). Builds on the browser terminal (docs/PLAN-web-backend.md, scripts/web_terminal.py).

## Context (checked 2026-11-08 on develop)
- The web interface has a serial-style terminal for the host and for instances (scripts/web_terminal.py): a hand-written RFC 6455 WebSocket, one-use
  tickets bound to the web session (`POST /api/terminal`, `GET /api/terminal/ws?ticket=`), same-origin check, limits, idle and lifetime timeouts,
  closed when the web session ends, behind the `webTerminal` switch. Only Domain Admins and the local adminuser sign in at all.
- A VM that needs a screen (an installer, Windows, a guest without a serial login) cannot be reached that way. Incus can show a VM's screen:
  `incus console <vm> --type=vga` and the REST call `POST /1.0/instances/<name>/console` with `{"type":"vga"}` return an operation with two
  WebSocket streams (`0` carries the SPICE protocol, `control` is for resizing); each stream has a one-use secret and is reached on Incus's unix
  socket (`/var/lib/incus/unix.socket`, root). Incus's own web UI uses this call. No TCP port is opened by Incus for it.
- hs-web runs as root on the host and already talks to Incus through the `incus` command, never through a TCP listener.
- No Incus is installed on the development machine, so nothing below ran against a real VM.

## Options

| | A. Incus console API (VGA, SPICE over WebSocket) | B. VNC (QEMU `-vnc` via `raw.qemu`) | C. SPICE with a TCP/unix listener we configure |
| --- | --- | --- | --- |
| Port on the network | none: unix socket, one-use secret per stream | a listener per VM (unix socket possible, but we would manage it) | a listener per VM |
| Change to the VM config | none | `raw.qemu` per VM: survives upgrades badly, can break Incus's own display handling | `raw.qemu` too |
| Authentication | Incus operation secret (we hold it, the browser never sees it) | VNC password is weak (8 characters, DES); the socket path is the real protection | ticket in SPICE, same problem |
| Works for every VM Incus starts | yes (needs the VM's virtual GPU, which Incus adds) | only VMs we configured | only VMs we configured |
| Browser client | SPICE: spice-html5 (LGPL) is the one that exists, only as a stale 2018 "bower" copy on npm; Incus's UI vendors its own copy | noVNC: maintained, MPL-2.0, `@novnc/novnc` on npm | spice-html5 again |
| Clipboard, audio, USB | SPICE could do more, Incus's stream carries the display and input | basic | all |

## Decision
1. **Incus's own console API (option A).** The web interface asks Incus for a VGA console of a running VM and relays the SPICE stream; it does not
   configure VNC or SPICE listeners and never changes a VM's config. VNC (B) is not offered: it needs per-VM `raw.qemu`, which is more
   attack surface and more to maintain, and its password is not authentication.
2. **No port is exposed, no unauthenticated WebSocket.** The only listener is hs-web's existing one. `POST /api/vmconsole {target}` needs a signed-in
   session and the CSRF token, `webTerminal` on (the console is a keyboard on the machine: same switch, same risk, one setting to explain), the
   storage unlocked, and a target that is a running virtual machine (a container gets 409: it keeps the terminal). It returns a 30 second
   one-use ticket bound to the session. `GET /api/vmconsole/ws?ticket=` needs the same session cookie, a same-origin request and a valid
   upgrade; the ticket is spent on the first try. The Incus operation secrets are used only inside hs-web on the unix socket and are never sent to the
   browser or logged. Tickets are held in memory only (a restart invalidates them).
3. **Limits:** 2 consoles in total, 1 per web session (a graphical stream is heavy); the idle time and the longest connection follow
   `webTerminalIdleMinutes` and `webTerminalMaxHours`; the stream ends when the web session ends or expires, when the storage gets locked, or when Incus ends it.
   Browser frames are limited to 64 KiB, frames from Incus to 4 MiB. The stream itself is never logged: the journal gets "open" and "close" with user, VM and reason.
4. **Same-origin only:** the existing `connect-src` rule for the terminal (CSP names the page's own host) covers the new socket.
5. **Role:** today every signed-in user is an administrator. When the access ADR (roles) exists, the console and the terminal move to the same permission; until then they share `webTerminal`.
6. **The viewer is a follow-up.** No SPICE client library passes the dependency rules today (pinned, maintained, shippable licence, via npm). The page
   (Instances > a VM > Console) does the whole handshake and receives the stream, `web/src/shell/vmviewer.js` is the one place to plug a viewer in, and
   until then the window says that the picture cannot be shown yet. The follow-up is one of: vendor spice-html5 from its upstream repository after a licence and security
   review (the LGPL means shipping the library's source unmodified as its own file), or write a minimal client for the display and input channels.

## Consequences
- Nothing about the VM changes, so nothing has to be undone and the feature cannot weaken a VM that never uses it.
- The relay depends on Incus's console API shape (`fds."0"`, `fds.control`, `/1.0/operations/<id>/websocket?secret=`). It is tested only against a fake of that shape
  (tests/web-vmconsole-test.py); a first run on a real server may show a difference, and that is why the status stays Proposed.
- The viewer is open work: until it lands the feature is the secured transport and a window that says so.

## Open points
- Which viewer (rule 6). Resizing (`control` stream) and keyboard layout are viewer questions.
- Whether the console needs its own switch instead of sharing `webTerminal` once roles exist (rule 5).
- Not tested on hardware yet: opening a console of a real VM, a Windows guest, a guest without a GPU.
