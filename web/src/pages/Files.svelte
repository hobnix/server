<script>
  // Storage > Files: a two-pane file manager for disks, pools, shares and temporary disks (docs/PLAN-file-manager.md, web/design/HANDOFF.md "Files").
  // Nothing runs from a click or a key: copy, move, delete, rename and new folder open a plan first (files/FmPlan.svelte). The same-files rule (a pool
  // disk and the pool of the same array never meet) is enforced by the server; the picker and the plan dialog only show its answer.
  // Links open it pre-filled: /storage/files?left=disk:data-04&path=/shares/x&right=pool:bulk[&rpath=/y][&select=<name>].
  import { onDestroy, untrack } from 'svelte';
  import { tip } from '../ui/tooltip.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Banner from '../ui/Banner.svelte';
  import Split from '../ui/Split.svelte';
  import Drawer from '../ui/Drawer.svelte';
  import Kv from '../ui/Kv.svelte';
  import Chip from '../ui/Chip.svelte';
  import { route } from '../route.svelte.js';
  import { Fm } from '../files/fm.svelte.js';
  import FmPane from '../files/FmPane.svelte';
  import FmPlan from '../files/FmPlan.svelte';
  import FmJob from '../files/FmJob.svelte';
  import FmResult from '../files/FmResult.svelte';
  import FmKeys from '../files/FmKeys.svelte';
  import * as S from '../files/selection.js';

  let { deck } = $props();
  const fm = new Fm();
  let root;
  // nothing is read while the storage is locked (the frame shows the lock banner), and not before the status document has said so
  let started = false;
  $effect(() => {
    if (started || !deck?.loaded || deck.data?.locked) return;
    started = true;
    untrack(() => fm.init(route.query));
  });
  onDestroy(() => fm.destroy());

  const a = $derived(fm.panes[fm.active]);
  const sel = $derived(fm.source());
  const why = (op) => fm.can(op);
  const infoRow = $derived(fm.info ? fm.panes[fm.info.side].rows.find((r) => r.name === fm.info.name) ?? null : null);
  const infoLoc = $derived(fm.info ? fm.locOf(fm.panes[fm.info.side].loc) : null);

  function showInfo() {
    if (fm.info) { fm.info = null; return; }
    const p = fm.panes[fm.active];
    const name = p.cur || [...p.sel][0];
    if (name) fm.info = { side: fm.active, name };
  }

  // ── the keyboard (Midnight Commander habits); a key in a text field or on a button is that control's own ─────────────────────────────────
  function onkey(e) {
    const t = e.target;
    if (t.closest?.('input, textarea, select')) return;
    if (fm.dialog || fm.keys || fm.result || fm.picker) return;
    const onBtn = !!t.closest?.('button');
    const mod = e.ctrlKey || e.metaKey;
    const act = (fn) => { e.preventDefault(); fn(); };
    switch (e.key) {
      case 'ArrowDown': return act(() => fm.move(1));
      case 'ArrowUp': return act(() => fm.move(-1));
      case 'Home': return act(() => { fm.panes[fm.active].cur = fm.orderNames(fm.active)[0] ?? ''; });
      case 'End': return act(() => { const o = fm.orderNames(fm.active); fm.panes[fm.active].cur = o[o.length - 1] ?? ''; });
      case ' ': case 'Insert': if (onBtn) return; return act(() => fm.spaceToggle());
      case 'Enter': if (onBtn) return; return act(() => { const p = fm.panes[fm.active]; const r = p.rows.find((x) => x.name === p.cur); if (r?.type === 'd') fm.open(fm.active, r.name); else if (r) showInfo(); });
      case 'Backspace': return act(() => fm.up(fm.active));
      case 'Tab': if (e.shiftKey) return; return act(() => fm.activate(fm.active === 'L' ? 'R' : 'L'));
      case 'Escape': return act(() => { if (fm.info) fm.info = null; else if (fm.patOpen) fm.patOpen = false; else if (fm.panes[fm.active].sel.size) fm.clear(); else fm.clearTray(); });
      case 'F2': return act(() => fm.plan('rename'));
      case 'F3': return act(showInfo);
      case 'F5': return act(() => fm.plan('copy'));
      case 'F6': return act(() => fm.plan('move'));
      case 'F7': return act(() => fm.plan('mkdir'));
      case 'F8': case 'Delete': return act(() => fm.plan('delete'));
      case '/': return act(() => root.querySelector(`[data-fmfilter="${fm.active}"]`)?.focus());
      case '?': return act(() => (fm.keys = true));
      case '*': return act(() => fm.invert());
      case '+': return act(() => { fm.patOpen = true; });
      case '-': case '_': return act(() => { fm.patOpen = true; });
    }
    if (mod && (e.key === 'a' || e.key === 'A')) act(() => fm.selectAll());
    else if (mod && (e.key === 'r' || e.key === 'R')) act(() => fm.refresh());
  }
  // keep the cursor row in view
  $effect(() => {
    const cur = a.cur;
    if (!cur || !root) return;
    queueMicrotask(() => { for (const tr of root.querySelectorAll('tr[data-k]')) if (tr.dataset.k === cur && tr.closest('.fmpane.active')) { tr.scrollIntoView({ block: 'nearest' }); break; } });
  });

  const big = (op) => ({ copy: 'F5', move: 'F6', rename: 'F2', mkdir: 'F7', delete: 'F8' })[op];
  const tipOf = (op, text) => ({ text: why(op) ? `${text}: ${why(op)}` : text, keys: big(op) });
</script>

<PageHeader title="Files" crumb="Storage" sub="Copy and move between disks and pools. Nothing runs from a click: every operation opens a plan first.">
  {#snippet actions()}
    <button class="btn" use:tip={{ text: 'Show the keyboard shortcuts', keys: '?' }} onclick={() => (fm.keys = true)}><i class="ph ph-keyboard"></i>Shortcuts</button>
  {/snippet}
</PageHeader>

<FmJob {fm} />
{#if !fm.write && fm.locsState === 'ok'}
  <div class="fmnote"><Banner tone="info">{S.WRITE_OFF} Browsing and dry runs work; Start is switched off.</Banner></div>
{/if}
{#if fm.notice}
  <div class="fmnote"><Banner tone="warn">{fm.notice}{#snippet action()}<button class="btn sm" onclick={() => (fm.notice = '')}>OK</button>{/snippet}</Banner></div>
{/if}

<PageState loading={fm.locsState === 'loading'} error={fm.locsState === 'error' ? fm.locsError : ''} hasData={fm.locs.length > 0} empty={fm.locsState === 'ok' && !fm.locs.length}
           emptyIcon="folders" emptyTitle={fm.locked ? 'The storage is locked' : 'Nothing to browse yet'} emptyText={fm.locked ? 'Unlock the encrypted storage first; then the disks, pools and shares appear here.' : 'There are no disks, pools or shares to show. Add a pool or a share first.'} retry={() => fm.init(route.query)}>
  <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
  <div class="fm" bind:this={root} tabindex="0" role="application" aria-label="File manager" onkeydown={onkey}>
    <div class="fmtools">
      <div class="fmgrp">
        <button class="btn sm pho" disabled={!!why('copy')} use:tip={tipOf('copy', 'Copy to the other pane')} onclick={() => fm.plan('copy')}><i class="ph ph-copy"></i>Copy<span class="kbd">F5</span></button>
        <button class="btn sm pho" disabled={!!why('move')} use:tip={tipOf('move', 'Move to the other pane')} onclick={() => fm.plan('move')}><i class="ph ph-arrows-left-right"></i>Move<span class="kbd">F6</span></button>
        <button class="btn sm pho" disabled={!!why('rename')} use:tip={tipOf('rename', 'Rename')} onclick={() => fm.plan('rename')}><i class="ph ph-pencil-simple"></i>Rename<span class="kbd">F2</span></button>
        <button class="btn sm" disabled={!!why('mkdir')} use:tip={tipOf('mkdir', 'Make a new folder here')} onclick={() => fm.plan('mkdir')}><i class="ph ph-folder-plus"></i>New folder<span class="kbd">F7</span></button>
        <button class="btn sm danger-o pho" disabled={!!why('delete')} use:tip={tipOf('delete', 'Delete for good')} onclick={() => fm.plan('delete')}><i class="ph ph-trash"></i>Delete<span class="kbd">F8</span></button>
      </div>
      <div class="fmgrp">
        <button class="btn sm btn-ghost" disabled={!a.cur && !a.sel.size} use:tip={{ text: 'Size, time and which disks hold it', keys: 'F3' }} onclick={showInfo}><i class="ph ph-info"></i>Info<span class="kbd">F3</span></button>
        <button class="btn sm btn-ghost" use:tip={{ text: 'Select or deselect by a pattern such as *.mkv', keys: '+' }} onclick={() => (fm.patOpen = !fm.patOpen)}>Select by pattern<span class="kbd">+</span></button>
      </div>
      <span class="grow"></span>
      <div class="fmgrp">
        <button class="btn sm btn-ghost pho" use:tip={'Show the same place in the active pane'} onclick={() => fm.same(fm.active)}>Same as other pane</button>
        <button class="btn sm btn-ghost" use:tip={'Exchange the two panes'} onclick={() => fm.swap()}><i class="ph ph-arrows-left-right"></i>Swap panes</button>
        <button class="btn btn-ghost btn-icon sq" aria-label="Refresh" use:tip={{ text: 'Read both lists again', keys: 'Ctrl R' }} onclick={() => fm.refresh()}><i class="ph ph-arrow-clockwise"></i></button>
      </div>
    </div>

    {#if fm.tray.length}
      <div class="fmpat tray">
        <i class="ph ph-stack"></i><span><b>Tray:</b> {S.plural(fm.tray.length, 'item')} from {fm.label(fm.trayLoc)}. They join the selection of any pane on that location.</span>
        <span class="grow"></span>
        <button class="btn sm" onclick={() => fm.clearTray()}>Empty the tray</button>
      </div>
    {/if}
    {#if fm.patOpen}
      <div class="fmpat">
        <span class="eyebrow">Pattern</span>
        <!-- svelte-ignore a11y_autofocus -->
        <input class="input" type="text" placeholder="*.mkv" aria-label="Glob pattern" autofocus bind:value={fm.pat}
               onkeydown={(e) => { e.stopPropagation(); if (e.key === 'Enter') fm.byPattern(false); else if (e.key === 'Escape') { fm.patOpen = false; root.focus(); } }} />
        <button class="btn sm" onclick={() => fm.byPattern(false)}>Select</button>
        <button class="btn sm" onclick={() => fm.byPattern(true)}>Deselect</button>
        <span class="muted">in the {fm.active === 'L' ? 'left' : 'right'} pane. * is any run of letters, ? is one.</span>
      </div>
    {/if}

    <div class="fmsw" role="group" aria-label="Pane">
      <button aria-pressed={fm.mobile === 'L'} onclick={() => fm.activate('L')}>Left</button>
      <button aria-pressed={fm.mobile === 'R'} onclick={() => fm.activate('R')}>Right</button>
    </div>

    <Split open={!!infoRow}>
      {#snippet list()}
        <div class="fmpanes"><FmPane {fm} side="L" /><FmPane {fm} side="R" /></div>
      {/snippet}
      {#snippet side()}
        <Drawer title={infoRow.name} chip={infoRow.type === 'd' ? 'folder' : infoRow.type === 'l' ? 'link' : 'file'} onclose={() => (fm.info = null)}>
          <Kv items={[
            { k: 'Size', v: infoRow.type === 'd' && !Number.isFinite(infoRow.bytes) ? 'not calculated' : S.bytesTxt(infoRow.bytes) },
            { k: 'Modified', v: S.dateTxt(infoRow.mtime) },
            { k: 'Location', v: infoLoc?.label },
            { k: 'Type', v: infoRow.type === 'd' ? 'Folder' : infoRow.type === 'l' ? 'Symbolic link' : 'File' },
          ]} />
          <div class="ipath"><div class="k">Path</div><div class="mono">{S.joinPath(fm.panes[fm.info.side].path, infoRow.name)}</div></div>
          {#if infoRow.disks.length}
            <div class="ipath"><div class="k">Held by disks</div><div class="chips">{#each infoRow.disks as d}<Chip>{d}</Chip>{/each}</div>
              <div class="sm">{infoRow.disks.length > 1 ? 'The pieces of this folder are on more than one disk.' : 'Only this disk holds it.'}</div></div>
          {/if}
          {#if infoRow.flags.length}<div class="ipath"><div class="k">Flags</div><div class="chips">{#each infoRow.flags as f}<Chip>{f}</Chip>{/each}</div></div>{/if}
          {#if S.lockOf(infoRow, fm.ctxOf(fm.info.side)).locked}<div class="ipath"><div class="k">Locked</div><div class="sm">{S.lockOf(infoRow, fm.ctxOf(fm.info.side)).reason}</div></div>{/if}
        </Drawer>
      {/snippet}
    </Split>

    <!-- a phone: a selection mode with the actions in a bar at the bottom -->
    {#if sel.n}
      <div class="fmbar">
        <b>{sel.n}</b><span class="grow"></span>
        <button class="btn sm" disabled={!!why('copy')} onclick={() => fm.plan('copy')}>Copy</button>
        <button class="btn sm" disabled={!!why('move')} onclick={() => fm.plan('move')}>Move</button>
        <button class="btn sm danger-o" disabled={!!why('delete')} onclick={() => fm.plan('delete')}>Delete</button>
        <button class="btn sm btn-ghost" disabled={!!why('rename')} onclick={() => fm.plan('rename')}>Rename</button>
        <button class="btn sm btn-ghost" aria-label="Clear" onclick={() => fm.clear()}><i class="ph ph-x"></i></button>
      </div>
    {/if}
  </div>
</PageState>

{#if fm.dialog}<FmPlan {fm} />{/if}
{#if fm.keys}<FmKeys onclose={() => { fm.keys = false; root?.focus(); }} />{/if}
{#if fm.result}<FmResult {fm} />{/if}

<style>
  :global(.wrap:has(.fm)) { max-width: none; }
  .fmnote { margin-bottom: 12px; }
  .fm { position: relative; outline: none; display: flex; flex-direction: column; min-width: 0; }
  .fmtools { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; margin-bottom: 12px; padding: 8px 10px; border: 1px solid var(--line); background: var(--panel); }
  .fmgrp { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
  .fmgrp + .fmgrp { padding-left: 14px; border-left: 1px solid var(--line); }
  .kbd { margin-left: 6px; font: 500 10.5px var(--mono); color: var(--fg-3); padding: 0 4px; border: 1px solid var(--line-2); }
  .danger-o { color: var(--bad-ink); }
  .danger-o:disabled { color: inherit; }
  .sq { width: 28px; min-height: 28px; height: 28px; padding: 0; }
  .fmpat { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin: -4px 0 12px; padding: 8px 10px; border: 1px solid var(--line); background: var(--panel); font-size: 12.5px; }
  .fmpat .input { width: 160px; min-height: 28px; height: 28px; }
  .muted { color: var(--fg-3); }
  .fmsw { display: none; margin-bottom: 12px; border: 1px solid var(--line-2); }
  .fmsw button { flex: 1; height: 34px; border: 0; background: none; color: var(--fg-2); }
  .fmsw button[aria-pressed='true'] { background: color-mix(in oklch, var(--accent) 18%, transparent); color: var(--fg); font-weight: 600; }
  .fmpanes { display: flex; gap: 12px; align-items: flex-start; }
  .fmbar { display: none; }
  .ipath { padding: 10px 16px; border-bottom: 1px solid var(--line); overflow-wrap: anywhere; }
  .ipath .k { font: 500 11px var(--mono); letter-spacing: 0.06em; text-transform: uppercase; color: var(--fg-3); margin-bottom: 4px; }
  .chips { display: flex; gap: 4px; flex-wrap: wrap; }
  .sm { font-size: 12px; color: var(--fg-3); margin-top: 4px; }
  @media (max-width: 860px) {
    .fmsw { display: flex; }
    .fmpanes { flex-direction: column; }
    .fmgrp + .fmgrp { padding-left: 0; border-left: 0; }
    .fmgrp .pho, .kbd { display: none; }
    .fmgrp:nth-child(2) { display: none; }
    .fmtools { padding: 6px; gap: 8px; }
    .fm { padding-bottom: 64px; }
    .fmbar { display: flex; position: fixed; left: 0; right: 0; bottom: 0; z-index: 20; align-items: center; gap: 8px; padding: 10px 14px; background: var(--panel); border-top: 1px solid var(--line-2); flex-wrap: wrap; }
  }
</style>
