<script>
  // A shell in a window over the page (a tmux session on the server: closing or popping out only detaches, the next one reattaches): the host (like an SSH login as adminuser) or inside one instance. The keys go to the server
  // over one WebSocket (binary frames for data, a small JSON text frame for the size); a one-use ticket opens it (POST /api/terminal).
  import { onMount } from 'svelte';
  import { terminalTicket } from '../api.js';
  import { ui } from '../ui.svelte.js';

  let { target = 'host', title = '', page = false } = $props();

  let box = $state(null);
  let state = $state('connecting');          // connecting | open | closed
  let note = $state('');
  let term, fit, ws;
  const enc = new TextEncoder();
  const REASONS = { 4001: 'Closed after 30 minutes without typing. Your shell keeps running: Reconnect picks it up.', 4002: 'Closed after the 8 hour limit. Your shell keeps running: Reconnect picks it up.', 4003: 'Your web session ended.' };

  // a CSS colour (hex, oklch, ...) as rgb, so xterm can read it; alpha for the selection
  function rgb(value, alpha) {
    const c = document.createElement('canvas').getContext('2d');
    c.fillStyle = '#000';
    c.fillStyle = value;
    const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(c.fillStyle);
    if (!m) return alpha === undefined ? c.fillStyle : `rgba(150,140,220,${alpha})`;
    return alpha === undefined ? c.fillStyle : `rgba(${parseInt(m[1], 16)},${parseInt(m[2], 16)},${parseInt(m[3], 16)},${alpha})`;
  }
  function theme() {
    const cs = getComputedStyle(document.documentElement);
    const v = (n) => cs.getPropertyValue(n).trim();
    return { background: rgb(v('--color-bg')), foreground: rgb(v('--color-text')), cursor: rgb(v('--color-accent')), cursorAccent: rgb(v('--color-bg')), selectionBackground: rgb(v('--color-accent'), 0.3) };
  }

  function sendSize() {
    if (ws && ws.readyState === WebSocket.OPEN && term) ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
  }

  async function connect() {
    state = 'connecting';
    note = '';
    let sock;
    try {
      const { ticket } = await terminalTicket(target);
      sock = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/api/terminal/ws?ticket=${encodeURIComponent(ticket)}`);
    } catch (e) {
      state = 'closed';
      note = e.message;
      return;
    }
    ws = sock;
    sock.binaryType = 'arraybuffer';
    sock.onopen = () => { state = 'open'; fit.fit(); sendSize(); term.focus(); };
    sock.onmessage = (ev) => { if (ev.data instanceof ArrayBuffer) term.write(new Uint8Array(ev.data)); };
    sock.onclose = (ev) => {
      if (ws !== sock) return;
      const was = state;
      state = 'closed';
      note = REASONS[ev.code] || (ev.code === 1006 ? (was === 'open' ? 'The connection dropped.' : 'The terminal could not be opened.') : '');
      term.write('\r\n\x1b[2m[connection closed]\x1b[0m\r\n');
    };
  }

  function reconnect() {
    term.reset();
    connect();
  }

  // the same shell in a window of its own: this one closes, the new one asks for its own ticket
  function popout() {
    const q = new URLSearchParams({ terminal: target, title: title || target });
    const w = window.open(`/?${q}`, '_blank', `popup=yes,width=1000,height=680,left=${Math.max(0, (screen.width - 1000) / 2)},top=${Math.max(0, (screen.height - 680) / 2)},resizable=yes,scrollbars=no,toolbar=no,menubar=no,location=no,status=no`);
    if (w) close(); else note = 'The browser blocked the new window.';
  }

  function close() {
    const s = ws;
    ws = null;
    if (s) s.close(1000);
    if (page) window.close(); else ui.create = null;
  }

  // xterm is loaded when the first terminal opens (its own chunk: the page itself stays small)
  onMount(() => {
    let ro, onWin, late, gone = false;
    if (page) document.title = `Terminal - ${title || target}`;
    (async () => {
      const [{ Terminal }, { FitAddon }] = await Promise.all([import('@xterm/xterm'), import('@xterm/addon-fit'), import('@xterm/xterm/css/xterm.css')]);
      if (gone) return;
      term = new Terminal({ fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: 13, cursorBlink: true, scrollback: 5000, theme: theme() });
      fit = new FitAddon();
      term.loadAddon(fit);
      term.open(box);
      fit.fit();
      // tmux has the mouse, so a selection is made by tmux and arrives as OSC 52 ("c;<base64>"): put it on the clipboard
      term.parser.registerOscHandler(52, (data) => {
        const b64 = data.slice(data.indexOf(';') + 1);
        if (b64 && b64 !== '?') {
          try {
            const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
            navigator.clipboard.writeText(new TextDecoder().decode(bytes)).catch(() => {});
          } catch { /* not valid base64 */ }
        }
        return true;
      });
      // no browser menu on right click (tmux's own menu is switched off on the server)
      box.addEventListener('contextmenu', (e) => e.preventDefault());
      term.onData((d) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(enc.encode(d)); });
      term.onResize(sendSize);
      // maximise / fullscreen from the window bar resizes the window in steps (animation) and the observer can
      // fire before the layout has settled: fit on the next frame and once more shortly after
      const refit = () => { try { fit.fit(); } catch { /* the box is not visible yet */ } };
      onWin = () => { requestAnimationFrame(refit); clearTimeout(late); late = setTimeout(refit, 250); };
      ro = new ResizeObserver(onWin);
      ro.observe(box);
      window.addEventListener('resize', onWin);
      document.addEventListener('fullscreenchange', onWin);
      connect();
    })();
    return () => { gone = true; if (ro) ro.disconnect(); clearTimeout(late); if (onWin) { window.removeEventListener('resize', onWin); document.removeEventListener('fullscreenchange', onWin); } const s = ws; ws = null; if (s) s.close(1000); if (term) term.dispose(); };
  });
</script>

<!-- Escape belongs to the shell, and a click outside does not close the window: only the Close button does -->
<div class={page ? 'whole' : 'dialog-backdrop'} role="presentation" style={page ? '' : 'z-index:50'}>
  <div class={page ? 'whole-in' : 'dialog'} role="dialog" aria-modal="true" aria-labelledby="tt" style={page ? '' : 'width:min(1000px,100%);height:min(680px,calc(100vh - 40px));gap:12px'}>
    <!-- in a window of its own the terminal is the whole page: the bar only appears when the connection has ended -->
    {#if !page || state === 'closed'}
    <div style="display:flex;align-items:center;gap:10px" class:slim={page}>
      <span class="dot {state === 'open' ? 'ok' : state === 'connecting' ? 'warn' : 'bad'}" title={state}></span>
      <div id="tt" class="dialog-title" style="flex:1">{page ? 'Disconnected' : `Terminal · ${title || target}`}</div>
      {#if note}<span class="note">{note}</span>{/if}
      {#if state === 'closed'}<button class="btn btn-secondary" onclick={reconnect}><i class="ph ph-plugs-connected"></i>Reconnect</button>{/if}
      {#if !page}<button class="btn btn-secondary" onclick={popout} title="Open this terminal in a window of its own (the same session)"><i class="ph ph-arrow-square-out"></i>Popout</button>{/if}
      {#if !page}<button class="btn btn-secondary" onclick={close}>Close</button>{/if}
    </div>
    {/if}
    <div class="term" class:full={page} bind:this={box}></div>
  </div>
</div>

<style>
  .whole { position: fixed; inset: 0; background: var(--color-bg); }
  .whole-in { height: 100%; display: flex; flex-direction: column; box-sizing: border-box; }
  .slim { padding: 6px 10px; }
  .term.full { padding: 0; border-radius: 0; }
  .term { flex: 1; min-height: 0; padding: 8px 6px 4px 10px; border-radius: var(--r); background: var(--color-bg); overflow: hidden; }
  .term :global(.xterm) { height: 100%; }
  .term :global(.xterm-viewport) { background: transparent !important; }
  .note { font-size: 12px; color: var(--color-neutral-400); }
</style>
