<script>
  import { tip } from '../../ui/tooltip.svelte.js';
  // The passphrase field and the Unlock button. The passphrase lives only in the input and in the one request; it is cleared after every attempt.
  // On success nothing else happens here: the Shell polls the status document and the page shows the open storage by itself.
  let { width = '100%' } = $props();

  let input;
  let busy = $state(false);
  let error = $state('');
  let done = $state(false);

  async function post(pass) {
    const s = await fetch('/api/session', { credentials: 'same-origin' });
    if (!s.ok) throw new Error('Your session ended. Sign in again.');
    const { csrf } = await s.json();
    const r = await fetch('/api/unlock', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
      body: JSON.stringify({ passphrase: pass }),
    });
    let data = null;
    try { data = await r.json(); } catch { /* no body */ }
    if (r.ok && data && data.status === 'ok') return data;
    throw new Error((data && (data.reason || data.error)) || `Request failed (${r.status})`);
  }

  async function unlock(e) {
    e?.preventDefault();
    if (busy || !input || !input.value) return;
    const pass = input.value;
    input.value = '';
    busy = true;
    error = '';
    try {
      await post(pass);
      done = true;
    } catch (err) {
      error = err.message;
    } finally {
      busy = false;
    }
  }
</script>

<form class="uf" onsubmit={unlock} style="width:{width}">
  <label class="lab" for="unlock-pp">Passphrase</label>
  <div class="unl">
    <input id="unlock-pp" type="password" autocomplete="off" spellcheck="false" maxlength="256" bind:this={input}
      placeholder="One passphrase for every encrypted disk" disabled={busy || done}>
    <button use:tip={done ? 'Already unlocked' : busy ? 'Unlocking' : 'Unlock the encrypted storage with the passphrase'} class="btn sm" type="submit" disabled={busy || done}>
      {#if busy}<i class="ph ph-circle-notch spin"></i>Unlocking…{:else}<i class="ph ph-lock-key-open"></i>Unlock{/if}
    </button>
  </div>
  {#if busy}
    <div class="muted">Opening the disks and starting the services. This can take a minute; keep this page open.</div>
  {:else if done}
    <div class="ok"><i class="ph ph-check-circle"></i> Unlocked. The services are starting; this page updates by itself.</div>
  {:else if error}
    <div class="err" role="alert"><i class="ph ph-warning-circle"></i> {error}</div>
  {/if}
</form>

<style>
  /* one field with the neutral Unlock button inside it (the design's UnlockForm) */
  .uf { display: flex; flex-direction: column; gap: 8px; max-width: 100%; }
  .lab { font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-3); }
  .unl { position: relative; width: 100%; }
  .unl input { width: 100%; height: 36px; padding: 0 110px 0 12px; border: 1px solid var(--line-2); border-radius: var(--r); background: var(--panel-2); color: var(--fg); font: inherit; }
  .unl input::placeholder { color: var(--fg-3); }
  .unl input:focus-visible { border-color: var(--accent); outline: none; }
  .unl .btn { position: absolute; right: 4px; top: 4px; background: var(--panel-3); }
  .unl .btn:hover { background: var(--panel); border-color: var(--fg-3); }
  .muted { font-size: 12px; color: var(--fg-3); }
  .err { font-size: 12.5px; color: var(--bad-ink); }
  .ok { font-size: 12.5px; color: var(--ok-ink); }
  .spin { animation: unlock-spin 1s linear infinite; }
  @keyframes unlock-spin { to { transform: rotate(360deg); } }
</style>
