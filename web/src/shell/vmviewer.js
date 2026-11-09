// The seam for the graphical console's picture (ADR 0021). The server side is built: /api/vmconsole/ws relays the SPICE stream of the VM
// (Incus's own VGA console). Drawing it needs a SPICE client library, and none passes the repo's dependency rules yet (a maintained npm
// package with a licence we can ship; spice-html5 is only on npm as a stale 2018 "bower" copy). Until one is vendored, this returns null
// and VmConsole.svelte says so. To plug one in: return { feed(Uint8Array), send: (cb) => ..., destroy() } that draws into `box`.
export async function loadViewer(/* box, send */) {
  return null;
}
