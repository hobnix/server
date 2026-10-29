<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // One block of a GenericPage (see GenericPage.svelte for the whole declaration). Not used on its own except by the drawer of a table, which renders
  // its inner blocks with this component and the selected row as `row` (the context of `{field}` templates).
  import GenBlock from './GenBlock.svelte';
  import { poll, rows as rowsOf } from '../data.svelte.js';
  import { openPlan, openCreate } from '../ui.svelte.js';
  import { tpl, planArgs, buildRows, fmtValue, dotOf, isOn } from './generic.js';
  import Table from './Table.svelte';
  import UsageBar from './UsageBar.svelte';
  import PageState from './PageState.svelte';
  import Drawer from '../ui/Drawer.svelte';
  import Split from '../ui/Split.svelte';
  import Kv from '../ui/Kv.svelte';
  import Chip from '../ui/Chip.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import Switch from '../ui/Switch.svelte';
  import EmptyState from '../ui/EmptyState.svelte';

  // block: the declaration; row: the object of the selected row (drawer context); forms: { Name: Component }; data: { '/api/sys/..': { rows } } instead of polling
  let { block, row = null, forms = {}, data = null, tab = '' } = $props();

  // a read: the given answer (mock / test) or a poll
  function src(path, ms) {
    if (!path) return null;
    if (data && data[path]) return { data: data[path], error: null, loaded: true };
    return poll(path, ms);
  }
  const main = src(block.read, (block.every ?? 15) * 1000);
  const joinSrc = (block.joins ?? []).map((j) => src(j.read, (block.every ?? 15) * 1000));

  const cols = $derived(block.columns ?? []);
  const items = $derived(main ? buildRows(rowsOf(main), cols, block.joins ?? [], joinSrc.map((s) => rowsOf(s))) : []);
  const tableCols = $derived([
    ...cols.map((c) => ({ key: c.key, label: c.label ?? '', optional: c.optional, align: c.align, width: c.width, sort: c.sort ?? (c.kind === 'usage' ? false : undefined) })),
    ...(block.rowActions?.length ? [{ key: '_act', label: '', sort: false, align: 'right' }] : []),
  ]);
  const colOf = (k) => cols.find((c) => c.key === k);
  const lbl = (r) => fmtValue(colOf("title")?.fmt, r.title ?? r[block.key]);

  function run(a, r) {
    if (a.form) openCreate(forms[a.form], a.props ?? {});
    else if (a.plan) openPlan(a.plan[0], planArgs(a.plan, r), tpl(a.planTitle ?? a.label, r));
  }

  // table + drawer
  let sel = $state(null);                                        // key of the selected row
  let dtab = $state('');
  const selRow = $derived(sel === null ? null : items.find((r) => r[block.key] === sel) ?? null);
  $effect(() => { if (sel !== null && main?.loaded && !selRow) sel = null; });
  const drawer = $derived(block.drawer ?? null);
  const dstate = $derived(drawer?.state && selRow ? dotOf(colOf(drawer.state) ?? {}, selRow[drawer.state]) : null);

  // gallery
  let shown = $state('');
  const current = $derived(items.find((r) => r[block.key] === shown) ?? items[0]);
  let seen = 0;
  $effect(() => { const n = items.length; if (n > seen && seen > 0) shown = items[0][block.key]; seen = n; });   // a new picture is shown at once

  // kv from a read: [{ k, col }] on the first row (or `pairs`: every row is key, value); in a drawer: [{ k, field }] on the selected row
  const kvItems = $derived.by(() => {
    if (block.pairs) return rowsOf(main).map((r) => ({ k: r[0], v: clean(r[1]) }));
    if (row) return (block.items ?? []).map((it) => ({ k: it.k, v: fmtValue(it.fmt, row[it.field]) }));
    const first = rowsOf(main)[0] ?? [];
    return (block.items ?? []).map((it) => ({ k: it.k, v: fmtValue(it.fmt, clean(first[it.col ?? 0])) }));
  });
  const clean = (v) => (v === '-' ? '' : v);
</script>

{#snippet actionRow(list, r)}
  {#each list as a}
    {#if a.href}
      <a class="btn sm {a.danger ? 'btn-ghost' : 'btn-secondary'}" href={tpl(a.href, r)} download={a.download ? tpl(a.download, r) : undefined} use:tip={a.title ? tpl(a.title, r) : undefined}><i class="ph ph-{a.icon || 'download-simple'}"></i>{a.label}</a>
    {:else}
      <button class="btn sm {a.primary ? 'btn-primary' : a.danger ? 'btn-ghost' : 'btn-secondary'}" class:icon={a.iconOnly} use:tip={a.title ? tpl(a.title, r) : a.label} aria-label={a.iconOnly ? tpl(a.title ?? a.label, r) : undefined}
              onclick={(e) => { e.stopPropagation(); run(a, r); }}>{#if a.icon}<i class="ph ph-{a.icon}"></i>{/if}{#if !a.iconOnly}{a.label}{/if}</button>
    {/if}
  {/each}
{/snippet}

{#if block.type === 'table'}
  {#snippet list()}
    <div class="card gb">
      {#if block.title || block.actions?.length}
        <div class="gh"><b>{block.title ?? ''}</b><span class="grow"></span>{#if block.actions?.length}{@render actionRow(block.actions, {})}{/if}</div>
      {/if}
      <PageState loading={!main.loaded} error={main.error?.message ?? ''} hasData={main.data != null} empty={main.loaded && !items.length}
                 emptyIcon={block.emptyIcon ?? 'tray'} emptyTitle={block.emptyTitle ?? 'Nothing here yet'} emptyText={block.empty ?? ''}>
        <Table id={block.id ?? 'gen-' + (block.read ?? '')} columns={tableCols} rows={items} key={block.key} selected={sel} empty={block.empty ?? 'Nothing to show.'}
               onrow={block.onrow === 'drawer' && drawer ? (r) => { sel = sel === r[block.key] ? null : r[block.key]; } : null}>
          {#snippet cell(r, col)}
            {@const c = colOf(col.key)}
            {#if col.key === '_act'}
              <span class="acts">{@render actionRow(block.rowActions, r)}</span>
            {:else if c.kind === 'dot'}
              {@const d = dotOf(c, r[c.key])}<StatusDot state={d[0]} label={d[1]} />
            {:else if c.kind === 'usage'}
              <UsageBar used={r[c.used]} free={c.free ? r[c.free] : null} size={Number(r[c.size])} />
            {:else if c.kind === 'chip'}
              {#if r[c.key]}<Chip>{fmtValue(c.fmt, r[c.key])}</Chip>{/if}
            {:else if c.kind === 'switch'}
              <Switch checked={isOn(r[c.key])} label={c.label} disabled={!c.plan}
                      onchange={(on) => openPlan(c.plan[0], planArgs(c.plan, { ...r, checked: on ? 'on' : 'off' }), tpl(c.planTitle ?? c.label, r))} />
            {:else if c.kind === 'mono'}
              <span class="mono">{fmtValue(c.fmt, r[c.key]) || '–'}</span>
            {:else}
              <span class="txt">{#if c.icon}<i class="ph ph-{c.icon}"></i>{/if}{fmtValue(c.fmt, r[c.key])}</span>
            {/if}
          {/snippet}
        </Table>
      </PageState>
    </div>
  {/snippet}
  {#snippet side()}
    {#if selRow && drawer}
      <Drawer title={tpl(drawer.title ?? '{' + block.key + '}', selRow)} chip={drawer.chip ? tpl(drawer.chip, selRow) : ''} state={dstate?.[0] ?? ''} stateLabel={dstate?.[1] ?? ''}
              tabs={drawer.tabs ?? []} bind:tab={dtab} onclose={() => (sel = null)}>
        {#snippet children(active)}
          {#each (drawer.blocks ?? []).filter((b) => !b.tab || b.tab === active) as b}
            <div class="dpad"><GenBlock block={b} row={selRow} {forms} {data} /></div>
          {/each}
        {/snippet}
        {#snippet actions()}{#if drawer.actions?.length}{@render actionRow(drawer.actions, selRow)}{/if}{/snippet}
      </Drawer>
    {/if}
  {/snippet}
  {#if drawer && block.onrow === 'drawer'}
    <Split open={!!selRow} {list} {side} />
  {:else}
    {@render list()}
  {/if}

{:else if block.type === 'kv'}
  <div class={row ? '' : 'card gb'}>
    {#if block.title}<div class="gh"><b>{block.title}</b></div>{/if}
    <Kv items={kvItems} cols={block.cols ?? 2} />
  </div>

{:else if block.type === 'cards'}
  <PageState loading={!main.loaded} error={main.error?.message ?? ''} hasData={main.data != null} empty={main.loaded && !items.length} emptyText={block.empty ?? ''}>
    <div class="cards">
      {#each items as r (r[block.key ?? cols[0]?.key])}
        <div class="card gb">
          <div class="gh"><b>{tpl(block.cardTitle ?? '{' + (cols[0]?.key ?? '') + '}', r)}</b></div>
          <Kv items={cols.slice(1).map((c) => ({ k: c.label ?? c.key, v: fmtValue(c.fmt, r[c.key]) }))} cols={1} />
          {#if block.rowActions?.length}<div class="acts">{@render actionRow(block.rowActions, r)}</div>{/if}
        </div>
      {/each}
    </div>
  </PageState>

{:else if block.type === 'text'}
  <div class="card gb">
    {#if block.title}<div class="gh"><b>{block.title}</b></div>{/if}
    {#each [].concat(block.text ?? []) as para}<p class="para">{tpl(para, row ?? {})}</p>{/each}
  </div>

{:else if block.type === 'empty'}
  <div class="card"><EmptyState icon={block.icon ?? 'tray'} title={block.title ?? ''} text={block.text ?? ''} tone={block.tone ?? ''}>
    {#snippet action()}{#if block.actions?.length}<div class="acts">{@render actionRow(block.actions, {})}</div>{/if}{/snippet}
  </EmptyState></div>

{:else if block.type === 'gallery'}
  <PageState loading={!main.loaded} error={main.error?.message ?? ''} hasData={main.data != null} empty={main.loaded && !items.length}
             emptyIcon={block.emptyIcon ?? 'image'} emptyTitle={block.emptyTitle ?? 'Nothing here yet'} emptyText={block.empty ?? ''}>
    {#if current}
      <div class="card gb">
        <img class="big" src={tpl(block.image, current)} alt={lbl(current)} />
        <div class="grow-row">
          <span class="nm">{lbl(current)}</span><span class="meta">{[current.time && fmtValue('datetime', current.time), current.size && fmtValue('bytes', current.size)].filter(Boolean).join(' · ')}</span>
          <span class="grow"></span>
          {@render actionRow(block.rowActions ?? [], current)}
        </div>
      </div>
      {#if items.length > 1}
        <div class="thumbs">
          {#each items as r (r[block.key])}
            <button class="thumb" class:on={r[block.key] === current[block.key]} onclick={() => (shown = r[block.key])} use:tip={lbl(r)}><img src={tpl(block.image, r)} alt={lbl(r)} loading="lazy" /></button>
          {/each}
        </div>
      {/if}
    {/if}
  </PageState>
{/if}

<style>
  .gb { padding: 14px 16px; gap: 10px; overflow-x: auto; }
  .gh { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 14px; }
  .grow { flex: 1; }
  .acts { display: inline-flex; gap: 6px; align-items: center; }
  .btn.icon { width: 30px; padding: 0; justify-content: center; }
  .txt { display: inline-flex; align-items: center; gap: 7px; }
  .txt i { color: var(--fg-3); }
  .mono { font: 12px var(--mono); color: var(--fg-2); }
  .dpad { padding: 14px 16px; }
  .para { margin: 0; color: var(--fg-2); }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
  .big { width: 100%; max-width: 900px; display: block; border: 1px solid var(--line); }
  .grow-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .nm { text-transform: capitalize; font-weight: 500; }
  .meta { font-size: 12px; color: var(--fg-3); }
  .thumbs { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 10px; }
  .thumb { padding: 0; border: 1px solid var(--line); background: none; cursor: pointer; overflow: hidden; }
  .thumb.on { outline: 2px solid var(--accent); outline-offset: 1px; }
  .thumb img { width: 100%; display: block; }
</style>
