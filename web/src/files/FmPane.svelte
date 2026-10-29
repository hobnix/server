<script>
  // One pane of the file manager: the location button (grouped picker), breadcrumbs with Up, the free-space bar, the selection line, the states and the
  // sortable list. The state lives in the Fm object (fm.svelte.js); this draws it and turns clicks, keys and drags into calls on it.
  import { tip } from '../ui/tooltip.svelte.js';
  import Table from '../shell/Table.svelte';
  import UsageBar from '../shell/UsageBar.svelte';
  import Switch from '../ui/Switch.svelte';
  import Chip from '../ui/Chip.svelte';
  import Skeleton from '../ui/Skeleton.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import FmPicker from './FmPicker.svelte';
  import * as S from './selection.js';

  let { fm, side } = $props();
  const p = $derived(fm.panes[side]);
  const loc = $derived(fm.locOf(p.loc));
  const ctx = $derived(fm.ctxOf(side));
  const isActive = $derived(fm.active === side);
  const rows = $derived(fm.visible(side));
  const showDisks = $derived(!!loc && (loc.kind === 'pool' || loc.kind === 'share' || loc.kind === 'cache'));
  const totals = $derived(S.totals(p.rows, p.sel));
  const crumbs = $derived(S.crumbs(p.path));
  const jobHere = $derived(fm.jobHere(side));
  const phone = () => typeof matchMedia !== 'undefined' && matchMedia('(max-width: 860px)').matches;

  const columns = $derived([
    { key: 'chk', label: '', sort: false, width: '38px', head: true, cls: 'chk' },
    { key: 'name', label: 'Name', value: (r) => r.name },
    { key: 'size', label: 'Size', sort: 'num', align: 'right', width: '96px', value: (r) => r.bytes },
    { key: 'mod', label: 'Modified', sort: 'num', width: '134px', optional: true, value: (r) => r.mtime || NaN },
    ...(showDisks ? [{ key: 'disks', label: 'On disk', sort: false, width: '120px', optional: true }] : []),
  ]);

  const lockOf = (r) => S.lockOf(r, ctx);
  const rowClass = (r) => {
    const l = lockOf(r);
    return `fmrow${p.sel.has(r.name) ? ' sel' : ''}${isActive && p.cur === r.name ? ' cur' : ''}${l.locked ? ' prot' : ''}${dropRow === r.name ? ' drop' : ''}`;
  };
  const allOn = $derived.by(() => {
    const free = rows.filter((r) => !lockOf(r).locked);
    return free.length > 0 && free.every((r) => p.sel.has(r.name));
  });

  function onrow(r, e) {
    if (e.target.closest('button, a, input')) return;
    const l = lockOf(r);
    // a phone has no double click and no modifier keys: a folder opens on a tap, unless a selection is being made
    if (phone() && r.type === 'd' && l.openable && !p.sel.size) { fm.open(side, r.name); return; }
    if (phone() && p.sel.size && !l.locked) { fm.toggleRow(side, r); return; }
    fm.rowClick(side, r, e);
  }
  function ondbl(e) {
    const tr = e.target.closest('tr[data-k]');
    if (!tr || e.target.closest('button')) return;
    fm.open(side, tr.dataset.k);
  }

  // ── drag and drop ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  let dropRow = $state('');
  let dropPane = $state(false);
  const dragOK = (name) => {
    const d = fm.drag;
    if (!d) return false;
    if (name) {
      const r = p.rows.find((x) => x.name === name);
      if (!r || r.type !== 'd' || !lockOf(r).openable || lockOf(r).tag === 'system') return false;
      if (d.side === side && p.sel.has(name)) return false;      // not onto itself
      return true;
    }
    return d.side !== side;
  };
  function dstart(e) {
    const tr = e.target.closest('tr[data-k]');
    const r = tr && p.rows.find((x) => x.name === tr.dataset.k);
    if (!r || !fm.dragStart(side, r)) { e.preventDefault(); return; }
    e.dataTransfer.effectAllowed = 'copyMove';
    e.dataTransfer.setData('text/plain', [...p.sel].join('\n'));
    const g = document.createElement('div');
    g.textContent = S.plural(p.sel.size, 'item');
    g.style.cssText = 'position:fixed;top:-100px;padding:6px 10px;background:#444;color:#fff;font:12px sans-serif';
    document.body.appendChild(g);
    e.dataTransfer.setDragImage(g, 8, 8);
    setTimeout(() => g.remove(), 0);
  }
  function dover(e) {
    if (!fm.drag) return;
    const tr = e.target.closest('tr[data-k]');
    const name = tr?.dataset.k ?? '';
    const onFolder = name && dragOK(name);
    if (onFolder || (!onFolder && dragOK(''))) {
      e.preventDefault();
      e.dataTransfer.dropEffect = e.shiftKey ? 'move' : 'copy';
      dropRow = onFolder ? name : '';
      dropPane = !onFolder;
    } else { dropRow = ''; dropPane = false; }
  }
  function ddrop(e) {
    if (!fm.drag) return;
    e.preventDefault();
    const folder = dropRow;
    dropRow = ''; dropPane = false;
    fm.drop(side, folder, e.shiftKey);
  }
  function dleave(e) { if (!e.currentTarget.contains(e.relatedTarget)) { dropRow = ''; dropPane = false; } }
</script>

<section class="card xh fmpane" class:active={isActive} class:inactive={!isActive} class:offm={fm.mobile !== side} class:dropping={dropPane} aria-label={side === 'L' ? 'Left pane' : 'Right pane'}
         onpointerdown={(e) => { if (!e.target.closest('.fmhead, .fmpick')) fm.activate(side); }} ondragover={dover} ondrop={ddrop} ondragleave={dleave}>
  <div class="fmhead">
    <div class="fmloc">
      <button type="button" class="cmbtn fmlocbtn" aria-haspopup="listbox" aria-expanded={fm.picker === side} aria-label="Change location" use:tip={'Choose what this pane shows'} onclick={() => (fm.picker === side ? (fm.picker = null) : fm.openPicker(side))}>
        {#if loc}<Chip>{loc.kind}</Chip><b class="mono">{loc.label}</b>{#if loc.fs}<span class="fsx">{loc.fs}</span>{/if}{:else}<span class="fsx">{p.loc || 'Choose a location'}</span>{/if}
        <span class="cv" aria-hidden="true"></span>
      </button>
      {#if loc && !loc.writable}<span class="tag tag-neutral warnchip" use:tip={loc.reason || 'Nothing can be written here'}>{loc.modifiable ? 'closed' : 'read only'}</span>{/if}
      <span class="grow"></span>
      <input class="input fmfilter" type="search" placeholder="Filter" aria-label="Filter the list" data-fmfilter={side} bind:value={p.filter} onkeydown={(e) => { if (e.key === 'Escape') { p.filter = ''; e.currentTarget.blur(); e.stopPropagation(); } else if (e.key === 'Enter') e.currentTarget.blur(); else if (e.key !== 'Tab') e.stopPropagation(); }} />
      <button class="btn btn-ghost btn-icon sq" aria-pressed={p.hidden} aria-label="Show hidden files" use:tip={p.hidden ? 'Hide dot files' : 'Show dot files'} onclick={() => (p.hidden = !p.hidden)}><i class="ph ph-{p.hidden ? 'eye' : 'eye-slash'}"></i></button>
    </div>
    <div class="fmcrumb" aria-label="Path">
      <button class="btn btn-ghost btn-icon sq" aria-label="Up one folder" disabled={p.path === '/'} use:tip={{ text: 'Up one folder', keys: 'Backspace' }} onclick={() => fm.up(side)}><i class="ph ph-arrow-up"></i></button>
      <button class="crumbbtn" class:last={!crumbs.length} onclick={() => fm.goPath(side, '/')}>{loc?.label ?? '/'}</button>
      {#each crumbs as c, i (c.path)}<span class="sep" aria-hidden="true">/</span><button class="crumbbtn" class:last={i === crumbs.length - 1} onclick={() => fm.goPath(side, c.path)}>{c.name}</button>{/each}
    </div>
    {#if loc && loc.size > 0}
      <div class="fmfree"><UsageBar free={Number.isFinite(loc.free) ? loc.free : null} size={loc.size} width={170} /></div>
    {/if}
  </div>

  {#if fm.picker === side}<FmPicker {fm} {side} />{/if}

  <div class="fmsel">
    <span>{S.selText(totals)}</span>
    <span class="grow"></span>
    {#if totals.n}
      <button class="btn sm btn-ghost" use:tip={'Keep these and go on collecting in other folders'} onclick={() => { fm.active = side; fm.collect(); }}><i class="ph ph-stack-plus"></i>Add to tray</button>
      <button class="btn sm btn-ghost" use:tip={{ text: 'Clear the selection', keys: 'Esc' }} onclick={() => fm.clear(side)}>Clear</button>
    {/if}
  </div>

  {#if loc && !loc.writable}<div class="fmnote"><i class="ph ph-lock"></i>{loc.reason || 'This location is read only.'} {loc.modifiable ? 'Files can be moved or deleted here, but nothing can be added.' : 'It can be a source, never a target.'}</div>{/if}
  {#if jobHere}<div class="fmnote info"><i class="ph ph-arrows-clockwise"></i>A {fm.job.op} is running here; the list may change.</div>{/if}
  {#if p.status === 'error'}
    <div class="fmnote bad"><i class="ph ph-warning-octagon"></i><span class="grow">{p.error || 'This location stopped answering.'}{#if p.rows.length} Showing the last listing, greyed.{/if}</span>
      <button class="btn sm" onclick={() => fm.load(side)}><i class="ph ph-arrow-clockwise"></i>Try again</button></div>
  {/if}

  {#if p.status === 'loading'}
    <div class="fmskel"><Skeleton lines={6} height={14} gap={16} /></div>
  {:else if p.status === 'error' && !p.rows.length}
    <div class="fmnone"><EmptyState icon="plugs" title="Cannot show this folder" text="Check that the disk is still there, then try again." /></div>
  {:else}
    <div class="fmlist" class:greyed={p.status === 'error'} class:busy={p.busy} role="grid" tabindex="-1" ondragstart={dstart} ondragend={() => fm.dragEnd()} ondblclick={ondbl}>
      {#if p.rows.length}
        <Table id="fm-{side}" key="name" {columns} {rows} sort={{ key: 'name', dir: 'asc' }} first={(r) => r.type === 'd'} tabrows={false} bind:view={p.view} {onrow} {rowClass}
               draggable={(r) => !phone() && !lockOf(r).locked} empty={p.filter ? 'Nothing matches the filter.' : 'Nothing to show.'}>
          {#snippet headcell()}
            <Switch box checked={allOn} label="Select all" onchange={() => fm.selectAll(side)} />
          {/snippet}
          {#snippet cell(r, col)}
            {@const l = lockOf(r)}
            {#if col.key === 'chk'}
              <span class="chkw" role="presentation" onclick={(e) => e.stopPropagation()}>
                <Switch box checked={p.sel.has(r.name)} disabled={l.locked} reason={l.reason} label={`Select ${r.name}`} onchange={() => fm.toggleRow(side, r)} />
              </span>
            {:else if col.key === 'name'}
              <div class="nm">
                <i class="ph ph-{r.type === 'd' ? 'folder' : r.type === 'l' ? 'arrow-bend-down-right' : 'file'} ftype"></i>
                <span class="nmtxt">{r.name}</span>
                {#if r.flags.includes('link')}<span class="muted lk">link</span>{/if}
                {#if r.flags.includes('badname')}<span class="tag tag-neutral" use:tip={'The name has odd characters. It is shown escaped and cannot be renamed here.'}>odd name</span>{/if}
                {#if l.locked}<span class="tag lk-{l.tone}" use:tip={l.reason}>{l.tag}</span>{/if}
                {#if r.type === 'd' && l.openable}<button class="btn btn-ghost btn-icon sq opn" aria-label={`Open ${r.name}`} use:tip={'Open this folder'} onclick={() => fm.open(side, r.name)}><i class="ph ph-caret-right"></i></button>{/if}
                {#if showDisks && r.disks.length}<span class="dkb">{#each r.disks as d}<Chip>{d.replace('data-', 'd')}</Chip>{/each}</span>{/if}
              </div>
            {:else if col.key === 'size'}
              <span class="mono" class:dim={l.locked}>{r.type === 'd' && !Number.isFinite(r.bytes) ? '—' : S.bytesTxt(r.bytes)}</span>
            {:else if col.key === 'mod'}
              <span class:dim={l.locked}>{S.dateTxt(r.mtime)}</span>
            {:else if col.key === 'disks'}
              <span class="dks">{#each r.disks as d}<Chip>{d}</Chip>{/each}</span>
            {/if}
          {/snippet}
        </Table>
        {#if p.next}
          <div class="more"><button class="btn sm" disabled={p.busy} onclick={() => fm.load(side, { more: true })}><i class="ph ph-dots-three"></i>Load more</button><span class="muted">{p.rows.length} shown. The folder has more.</span></div>
        {/if}
      {:else}
        <div class="fmnone"><EmptyState icon="folder" title="This folder is empty" text="Drop files here, or copy them from the other pane." /></div>
      {/if}
    </div>
  {/if}
</section>

<style>
  .fmpane { flex: 1 1 0; min-width: 0; position: relative; padding: 0; }
  .fmpane.active::before { content: ''; position: absolute; left: -1px; right: -1px; top: -1px; height: 2px; background: var(--accent); z-index: 3; }
  .fmpane.inactive .fmhead { opacity: 0.88; }
  .fmpane.dropping { outline: 2px dashed var(--accent); outline-offset: -3px; }
  .fmhead { padding: 10px 12px 8px; border-bottom: 1px solid var(--line); display: flex; flex-direction: column; gap: 8px; }
  .fmloc { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .fmlocbtn { display: inline-flex; align-items: center; gap: 8px; min-width: 0; max-width: 100%; height: 32px; padding: 0 10px; border: 1px solid var(--line-2); border-radius: var(--r); background: var(--panel-2); color: var(--fg); font-size: 12.5px; text-align: left; }
  .fmlocbtn:hover { border-color: var(--fg-3); }
  .fmlocbtn[aria-expanded='true'] { border-color: var(--accent); }
  .cv { flex: none; width: 6px; height: 6px; border: solid var(--fg-3); border-width: 0 1.5px 1.5px 0; transform: rotate(45deg) translate(-2px, -2px); }
  .fmlocbtn b { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .fsx { font-size: 12px; color: var(--fg-3); }
  .warnchip { color: var(--warn-ink); border-color: color-mix(in oklch, var(--warn) 50%, var(--line)); }
  .fmfilter { width: 118px; min-height: 28px; height: 28px; padding: 2px 8px; font-size: 12.5px; }
  .sq { width: 28px; min-height: 28px; height: 28px; padding: 0; }
  .fmcrumb { display: flex; align-items: center; gap: 2px; overflow-x: auto; white-space: nowrap; }
  .fmcrumb .sep { color: var(--fg-3); }
  .crumbbtn { all: unset; cursor: pointer; padding: 2px 5px; color: var(--fg-2); font: 12.5px var(--mono); }
  .crumbbtn:hover { background: var(--panel-2); color: var(--fg); }
  .crumbbtn.last { color: var(--fg); font-weight: 600; }
  .fmfree { display: flex; align-items: center; gap: 10px; }
  .fmsel { display: flex; align-items: center; gap: 8px; min-height: 36px; padding: 2px 12px; border-bottom: 1px solid var(--line); color: var(--fg-2); font-size: 12.5px; background: color-mix(in oklch, var(--accent) 6%, transparent); }
  .fmnote { display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-bottom: 1px solid var(--line); color: var(--warn-ink); font-size: 12.5px; }
  .fmnote.bad { color: var(--bad-ink); }
  .fmnote.info { color: var(--info-ink); }
  .fmskel { padding: 14px 16px; }
  .fmlist.greyed { opacity: 0.45; }
  .fmlist.busy { opacity: 0.8; }
  .fmnone { padding: 8px 0; }
  .more { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-top: 1px solid var(--line); font-size: 12.5px; }
  .muted { color: var(--fg-3); }
  /* rows: the shared Table draws them; these are the file manager's own states */
  .fmlist :global(.table) { table-layout: fixed; }
  .fmlist :global(tr.fmrow td) { padding: 4px 10px; height: 34px; }
  .fmlist :global(tr.fmrow td.chk) { padding-left: 12px; padding-right: 0; }
  .fmlist :global(tr.fmrow:hover td) { background: var(--panel-2); }
  .fmlist :global(tr.fmrow.sel td) { background: color-mix(in oklch, var(--accent) 14%, transparent); }
  .fmlist :global(tr.fmrow.cur td:first-child) { box-shadow: inset 2px 0 0 var(--accent); }
  .fmlist :global(tr.fmrow.drop td) { background: color-mix(in oklch, var(--accent) 24%, transparent); outline: 1px dashed var(--accent); outline-offset: -1px; }
  .fmlist :global(tr.fmrow.prot) { cursor: default; }
  .fmlist :global(tr.fmrow.prot .ftype), .fmlist :global(tr.fmrow.prot .nmtxt) { opacity: 0.55; }
  .chkw { display: inline-flex; }
  .nm { display: flex; align-items: center; gap: 8px; min-width: 0; color: var(--fg); }
  .nmtxt { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 500; min-width: 0; }
  .ftype { flex: none; color: var(--fg-3); font-size: 16px; }
  .lk { white-space: nowrap; font-size: 12px; }
  .opn { margin-left: auto; opacity: 0.5; flex: none; }
  tr:hover .opn { opacity: 1; }
  .dim { opacity: 0.5; }
  .lk-warn { color: var(--warn-ink); border-color: color-mix(in oklch, var(--warn) 50%, var(--line)); }
  .lk-info { color: var(--info-ink); border-color: color-mix(in oklch, var(--info) 55%, var(--line)); background: color-mix(in oklch, var(--info) 12%, transparent); }
  .lk-off { color: var(--fg-3); }
  .dks { display: flex; gap: 4px; flex-wrap: wrap; }
  .dkb { display: none; gap: 4px; flex-wrap: wrap; }
  @media (max-width: 860px) {
    .fmpane { width: 100%; }
    .fmpane.offm { display: none; }
    .dkb { display: inline-flex; }
    .nm { flex-wrap: wrap; }
    .fmfilter { width: 90px; }
  }
</style>
