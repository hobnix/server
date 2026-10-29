<script>
  // The last lines of an instance's journal (`hs sys ct logs <ct> [lines]`, read only), in a window over the page.
  import { poll } from '../../data.svelte.js';
  import { ui } from '../../ui.svelte.js';
  import { backdropClose } from '../../ui/backdrop.js';

  let { ct } = $props();

  let lines = $state(200);
  let follow = $state(true);
  let box = $state(null);

  const logs = poll(() => (follow || !logs?.loaded ? `/api/sys/ct/logs/${encodeURIComponent(ct)}?lines=${lines}` : ''), 4000);
  const text = $derived((logs.data?.text ?? '').trimEnd());
  const list = $derived(text ? text.split('\n') : []);

  const cls = (l) => (/\b(error|err|fail|failed|crit|alert|emerg)\b/i.test(l) ? 'bad' : /\bwarn(ing)?\b/i.test(l) ? 'warn' : '');
  const close = () => { ui.create = null; };

  // keep the newest line in view while following
  $effect(() => { if (follow && box && list.length) box.scrollTop = box.scrollHeight; });
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && close()} />

<div class="dialog-backdrop" role="presentation" style="z-index:50" use:backdropClose={close}>
  <div class="dialog" role="dialog" aria-modal="true" aria-labelledby="ilt" style="width:min(960px,100%);height:min(640px,calc(100vh - 40px));gap:12px">
    <div style="display:flex;align-items:center;gap:10px">
      <div id="ilt" class="dialog-title" style="flex:1">Logs · {ct}</div>
      <label class="opt">Lines
        <select class="input" style="width:auto;min-height:26px;padding:2px 8px;font-size:12px" bind:value={lines}>
          <option value={100}>100</option><option value={200}>200</option><option value={500}>500</option><option value={1000}>1000</option>
        </select>
      </label>
      <label class="opt"><input type="checkbox" bind:checked={follow} />Follow</label>
      <button class="btn btn-secondary" onclick={close}>Close</button>
    </div>
    <div class="log" bind:this={box}>
      {#if logs.error && !logs.data}
        <div class="bad">The log could not be read (is the instance running, is the storage unlocked?).</div>
      {:else if !logs.loaded}
        <div class="dim">Loading…</div>
      {:else if !list.length}
        <div class="dim">The instance wrote nothing.</div>
      {:else}
        {#each list as l}<div class={cls(l)}>{l}</div>{/each}
      {/if}
    </div>
  </div>
</div>

<style>
  .opt { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--color-neutral-400); }
  .log { flex: 1; min-height: 0; overflow: auto; padding: 8px 10px; border-radius: var(--r); background: var(--color-bg); font-family: ui-monospace, Menlo, monospace; font-size: 11.5px; line-height: 1.5; white-space: pre-wrap; word-break: break-word; }
  .warn { color: var(--st-warn); }
  .bad { color: var(--st-bad); }
  .dim { color: var(--color-neutral-500); }
</style>
