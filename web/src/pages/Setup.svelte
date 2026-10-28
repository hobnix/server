<script>
  import { poll, rows } from '../data.svelte.js';
  import { go } from '../route.svelte.js';
  import { openPlan, ui } from '../ui.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import Banner from '../ui/Banner.svelte';

  const list = poll('/api/sys/setup/list', 8000);

  // id, state, label, command, page
  const items = $derived(rows(list).map((r) => ({ id: r[0], done: r[1] === 'done', label: r[2], cmd: r[3], page: r[4] })));
  const steps = $derived(items.filter((i) => i.id !== 'finished'));
  const finished = $derived(items.find((i) => i.id === 'finished')?.done ?? false);
  const doneCount = $derived(steps.filter((i) => i.done).length);
  const answered = $derived(!!list.data);
</script>

<div class="page">
  <PageHeader title="Setup" crumb={ui.host} sub={answered ? `${doneCount} of ${steps.length} steps done. Everything here can be done later.` : 'The first-run checklist.'}>
    {#snippet actions()}
      <button class="btn btn-primary b13" disabled={!answered || finished} onclick={() => openPlan('config', ['set', 'setupDone', 'true'], 'Setup finished')}>
        <i class="ph ph-check-circle"></i>{finished ? 'Setup is finished' : 'Mark setup as finished'}
      </button>
    {/snippet}
  </PageHeader>

  {#if list.error && !list.data}
    <Banner tone="bad">The checklist could not be read.</Banner>
  {/if}

  <div class="card" style="padding:4px 16px">
    {#each steps as s}
      <div class="row">
        <i class="ph ph-{s.done ? 'check-circle' : 'circle-dashed'}" style="font-size:20px;color:var({s.done ? '--st-ok' : '--st-warn'})"></i>
        <div style="flex:1;min-width:0">
          <div style="font-size:14px">{s.label}</div>
          {#if !s.done && s.cmd !== '-'}<div class="how">or in a terminal: <code>{s.cmd}</code></div>{/if}
        </div>
        {#if s.page && s.page !== '-'}
          <button class="btn {s.done ? 'btn-ghost' : 'btn-secondary'} b13" onclick={() => go(s.page)}>{s.done ? 'Open' : 'Set up'}<i class="ph ph-arrow-right"></i></button>
        {/if}
      </div>
    {/each}
    {#if !answered && !list.error}<div class="how" style="padding:12px 0">Loading…</div>{/if}
  </div>

  <div class="how">Everything here can be done later; this page only keeps track. Settings that need a rebuild are applied with <code>hs rebuild</code>.</div>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 16px; }
  .hd { display: flex; align-items: center; gap: 12px; }
  .crumb { font-size: 11px; color: var(--fg-3); }
  .tt { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
  .t { font-size: 20px; font-weight: 500; }
  .d { font-size: 12px; color: var(--fg-3); }
  .row { display: flex; align-items: center; gap: 14px; padding: 12px 0; box-shadow: inset 0 -1px 0 color-mix(in srgb, var(--fg) 6%, transparent); }
  .row:last-child { box-shadow: none; }
  .how { font-size: 12px; color: var(--fg-3); margin-top: 2px; word-break: break-word; }
  code { font-size: 12px; }
</style>
