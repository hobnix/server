<script>
  // The Logs tab of an instance drawer: the last lines of its journal (`hs sys ct logs <ct>`, read only), following while the tab is open.
  import { poll } from '../../data.svelte.js';

  let { ct } = $props();
  let lines = $state(200);
  let follow = $state(true);
  let box = $state(null);

  const logs = poll(() => (follow || !logs?.loaded ? `/api/sys/ct/logs/${encodeURIComponent(ct)}?lines=${lines}` : ''), 4000);
  const list = $derived(((logs.data?.text ?? '').trimEnd() || '').split('\n').filter((l, i, a) => a.length > 1 || l));
  const cls = (l) => (/\b(error|err|fail|failed|crit|alert|emerg)\b/i.test(l) ? 'bad' : /\bwarn(ing)?\b/i.test(l) ? 'warn' : '');
  $effect(() => { if (follow && box && list.length) box.scrollTop = box.scrollHeight; });
</script>

<div class="lt">
  <div class="bar">
    <label>Lines
      <select class="input" bind:value={lines}><option value={100}>100</option><option value={200}>200</option><option value={500}>500</option><option value={1000}>1000</option></select>
    </label>
    <label class="fol"><input type="checkbox" bind:checked={follow} />Follow</label>
  </div>
  <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
  <div class="log" bind:this={box} tabindex="0" role="log" aria-label="Journal of {ct}">
    {#if logs.error && !logs.data}
      <div class="bad">The log could not be read (is the instance running?).</div>
    {:else if !logs.loaded}
      <div class="dim">Loading…</div>
    {:else if !list.length}
      <div class="dim">The instance wrote nothing.</div>
    {:else}
      {#each list as l}<div class={cls(l)}>{l}</div>{/each}
    {/if}
  </div>
</div>

<style>
  .lt { display: flex; flex-direction: column; gap: 8px; padding: 12px 16px; }
  .bar { display: flex; align-items: center; gap: 14px; font-size: 12px; color: var(--fg-3); }
  .bar select { width: auto; min-height: 26px; padding: 2px 8px; font-size: 12px; margin-left: 6px; }
  .fol { display: inline-flex; align-items: center; gap: 6px; }
  .log { max-height: 46vh; min-height: 160px; overflow: auto; padding: 8px 10px; background: var(--bg); border: 1px solid var(--line); font: 11.5px/1.5 var(--mono); white-space: pre-wrap; word-break: break-word; }
  .warn { color: var(--warn); }
  .bad { color: var(--bad); }
  .dim { color: var(--fg-3); }
</style>
