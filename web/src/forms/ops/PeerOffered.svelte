<script>
  import { tip } from '../../ui/tooltip.svelte.js';
  // What the other server types after "Give access": shown once, in this browser tab only (nothing is stored; closing it forgets the password).
  let { offer, onclose } = $props();

  const s = $derived(offer.secret ?? {});
  const line = $derived(`hs remote add ${(s.host ?? '').replace(/\.local$/, '')} ${s.host ?? ''} ${offer.share} --user ${s.login ?? ''}${s.domain ? ' --domain ' + s.domain : ''}`);
  let copied = $state('');

  async function copy(what, text) {
    try { await navigator.clipboard.writeText(text); copied = what; } catch { copied = ''; }
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onclose()} />

<div class="dialog-backdrop" role="presentation" style="z-index:60">
  <div class="dialog" role="dialog" aria-modal="true" aria-labelledby="pot" style="width:min(560px,100%);gap:14px">
    <span class="kicker" style="color:var(--color-accent-300)">Remote shares</span>
    <div id="pot" class="dialog-title">{offer.peer} can read {offer.share}</div>
    <div class="lede">Tell the other person to run this on their server:</div>
    <pre class="code">{line}</pre>
    {#if s.password}
      <div class="lede">They are asked for this password. <b>It is shown only now</b> and is not kept anywhere on this server in a form you can read again.</div>
      <pre class="code pw">{s.password}</pre>
      <div class="dialog-actions">
        <button use:tip={'Copy the password to the clipboard'} class="btn btn-ghost" onclick={() => copy('pw', s.password)}><i class="ph ph-copy"></i>{copied === 'pw' ? 'Copied' : 'Copy password'}</button>
        <button use:tip={'Copy the command to the clipboard'} class="btn btn-ghost" onclick={() => copy('cmd', line)}><i class="ph ph-copy"></i>{copied === 'cmd' ? 'Copied' : 'Copy command'}</button>
        <span style="flex:1"></span>
        <button class="btn btn-primary" onclick={onclose}>I have noted it</button>
      </div>
    {:else}
      <div class="lede">The login existed already, so its password stays as it was. “New password…” on the row makes another one.</div>
      <div class="dialog-actions">
        <button use:tip={'Copy the command to the clipboard'} class="btn btn-ghost" onclick={() => copy('cmd', line)}><i class="ph ph-copy"></i>{copied === 'cmd' ? 'Copied' : 'Copy command'}</button>
        <span style="flex:1"></span>
        <button class="btn btn-primary" onclick={onclose}>Close</button>
      </div>
    {/if}
    <div class="hint">Take the access away again with “Revoke…” on the row.</div>
  </div>
</div>

<style>
  .code { margin: 0; padding: 8px 10px; border-radius: var(--r); background: var(--color-neutral-900); box-shadow: inset 0 0 0 1px var(--color-neutral-800); font-size: 12.5px; white-space: pre-wrap; word-break: break-all; user-select: all; }
  .pw { font-size: 14px; letter-spacing: 0.02em; }
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
