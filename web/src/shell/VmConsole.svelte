<script>
  // The graphical console of a virtual machine in a window over the page (ADR 0021): a one-use ticket (POST /api/vmconsole) opens one
  // WebSocket that carries the SPICE stream of the VM. Containers have no graphical console: they keep the terminal.
  // The picture itself needs a viewer library that is not bundled yet (shell/vmviewer.js): the window then says so.
  import Button from '../ui/Button.svelte';
  import Banner from '../ui/Banner.svelte';
  import { onMount } from 'svelte';
  import { vmConsoleTicket } from '../api.js';
  import { ui } from '../ui.svelte.js';
  import { tr } from '../i18n.js';
  import { loadViewer } from './vmviewer.js';

  let { target = '', title = '' } = $props();

  let box = $state(null);
  let state = $state('connecting');          // connecting | open | closed
  let note = $state('');
  let viewer = $state(null);
  let received = $state(0);
  let ws;
  const REASONS = { 4001: 'Closed after 30 minutes without input.', 4002: 'Closed after the 8 hour limit.', 4003: 'Your web session ended.' };

  async function connect() {
    state = 'connecting';
    note = '';
    received = 0;
    let sock;
    try {
      const { ticket } = await vmConsoleTicket(target);
      sock = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/api/vmconsole/ws?ticket=${encodeURIComponent(ticket)}`);
    } catch (e) {
      state = 'closed';
      note = e.message;
      return;
    }
    ws = sock;
    sock.binaryType = 'arraybuffer';
    sock.onopen = () => { state = 'open'; };
    sock.onmessage = (ev) => {
      if (!(ev.data instanceof ArrayBuffer)) return;
      received += ev.data.byteLength;
      if (viewer) viewer.feed(new Uint8Array(ev.data));
    };
    sock.onclose = (ev) => {
      if (ws !== sock) return;
      const was = state;
      state = 'closed';
      note = REASONS[ev.code] ? tr(REASONS[ev.code]) : ev.code === 1006 ? tr(was === 'open' ? 'The connection dropped.' : 'The console could not be opened.') : '';
    };
  }

  function close() {
    const s = ws;
    ws = null;
    if (s) s.close(1000);
    ui.create = null;
  }

  onMount(() => {
    let gone = false;
    (async () => {
      viewer = await loadViewer(box, (data) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(data); });
      if (!gone) connect();
    })();
    return () => { gone = true; const s = ws; ws = null; if (s) s.close(1000); if (viewer) viewer.destroy(); };
  });
</script>

<div class="dialog-backdrop" role="presentation" style="z-index:50">
  <div class="dialog" role="dialog" aria-modal="true" aria-labelledby="vt" style="width:min(1000px,100%);height:min(680px,calc(100vh - 40px));gap:12px">
    <div style="display:flex;align-items:center;gap:10px">
      <span class="dot {state === 'open' ? 'ok' : state === 'connecting' ? 'warn' : 'bad'}"></span>
      <div id="vt" class="dialog-title" style="flex:1">{tr('Console')} · {title || target}</div>
      {#if note}<span class="note">{note}</span>{/if}
      {#if state === 'closed'}<Button tooltip={tr('Open a new connection to the same console')} onclick={connect}><i class="ph ph-plugs-connected"></i>{tr('Reconnect')}</Button>{/if}
      <Button tooltip={tr('Close this window (the virtual machine keeps running)')} onclick={close}>{tr('Close')}</Button>
    </div>
    {#if !viewer}
      <Banner tone="info">{tr('The connection to the console works, but the picture cannot be shown yet: the viewer is not bundled with this version. Use the Incus console on the server meanwhile.')}</Banner>
    {/if}
    <div class="screen" bind:this={box}>
      {#if !viewer && state === 'open'}<span class="note">{tr('Received')}: {received} B</span>{/if}
    </div>
  </div>
</div>

<style>
  .screen { flex: 1; min-height: 0; background: #000; display: flex; align-items: center; justify-content: center; overflow: hidden; }
  .note { font-size: 12px; color: var(--fg2, #999); }
</style>
