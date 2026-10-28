<script>
  // The plan dialog of the file manager (copy, move, delete, rename, new folder). Nothing here starts by itself: the dialog asks the server for the plan
  // (`fm plan`), shows what would happen, and only the button starts the job. The conflict policy and the options are part of the question, so a
  // change asks again. Overwrite and delete turn it red and need the typed name; a refusal has only Close. Same pieces as shell/PlanDialog.svelte.
  import { onMount, untrack } from 'svelte';
  import { tip } from '../ui/tooltip.svelte.js';
  import { trackDone } from '../ui.svelte.js';
  import Chip from '../ui/Chip.svelte';
  import Skeleton from '../ui/Skeleton.svelte';
  import Halftone from '../shell/Halftone.svelte';
  import * as api from './api.js';
  import * as S from './selection.js';

  let { fm } = $props();
  const spec = $derived(fm.dialog);
  const op = $derived(spec.op);
  const moves = $derived(op === 'copy' || op === 'move');

  const POLICIES = [
    { id: 'skip', label: 'Skip existing', sub: 'Never overwrites anything. The default.' },
    { id: 'rename', label: 'Keep both', sub: 'The new file gets a number added to its name.' },
    { id: 'newer', label: 'Overwrite if newer', sub: 'Replaces a file only when the source is newer.', over: true },
    { id: 'overwrite', label: 'Overwrite always', sub: 'Replaces every file that exists on the target.', over: true },
  ];

  let opts = $state({ conflict: 'skip', verify: 'size', parity: false, newname: untrack(() => fm.dialog.name ?? '') });
  let p = $state(null);
  let loadErr = $state('');
  let loading = $state(true);
  let confirm = $state('');
  let busy = $state(false);
  let startErr = $state('');
  let showConf = $state(false);
  let confRows = $state(null);
  let confBusy = $state(false);
  let seq = 0;

  const overwrite = $derived(moves && POLICIES.find((x) => x.id === opts.conflict)?.over);
  const danger = $derived(op === 'delete' || overwrite);
  const refused = $derived(!!p && !p.ok);
  const need = $derived(p?.ok ? p.confirmName || (overwrite ? spec.toLabel : '') : '');
  const nameBad = $derived.by(() => {
    if (op !== 'rename' && op !== 'mkdir') return '';
    const n = opts.newname;
    if (!n.trim()) return 'Type a name';
    if (/[/\x00-\x1f]/.test(n)) return 'A name cannot contain / or control characters';
    if (n === '.' || n === '..') return 'That is not a name';
    if (op === 'rename' && n === spec.name) return 'That is the name it has already';
    return '';
  });
  const canStart = $derived(!!p?.ok && !loading && !busy && !nameBad && (!need || confirm === need));
  const verb = { copy: 'Copy', move: 'Move', delete: 'Delete permanently', rename: 'Rename', mkdir: 'Create folder' };
  const things = $derived(`${S.plural(spec.sum.n, 'item')}${spec.sum.dirs ? ` (${S.plural(spec.sum.dirs, 'folder')})` : ''}`);
  const title = $derived(p?.heading || ({ copy: `Copy ${things}`, move: `Move ${things}`, delete: `Delete ${things}`, rename: `Rename ${spec.name}`, mkdir: 'New folder' })[op]);
  const kicker = $derived(refused ? 'Plan · refused' : danger ? 'Plan · danger' : 'Plan');

  async function ask() {
    const my = ++seq;
    loading = true;
    loadErr = '';
    if ((op === 'rename' || op === 'mkdir') && nameBad) { loading = false; p = null; return; }
    try {
      const r = await api.plan(spec, opts);
      if (my !== seq) return;
      p = r;
      showConf = false;
      confRows = null;
    } catch (e) {
      if (my !== seq) return;
      loadErr = e.message;
      p = null;
    } finally {
      if (my === seq) loading = false;
    }
  }
  onMount(ask);
  // a change of policy, checksum, parity or name asks again (the name after a short pause)
  let t;
  let first = true;
  $effect(() => {
    opts.conflict; opts.verify; opts.parity; opts.newname;
    if (first) { first = false; return; }
    clearTimeout(t);
    t = setTimeout(() => untrack(ask), op === 'rename' || op === 'mkdir' ? 350 : 0);
    return () => clearTimeout(t);
  });

  async function showConflicts() {
    showConf = !showConf;
    if (!showConf || confRows) return;
    confBusy = true;
    try { confRows = (await api.plan(spec, { ...opts, conflicts: true })).conflictRows; }
    catch (e) { loadErr = e.message; confRows = []; }
    finally { confBusy = false; }
  }

  function close() { fm.dialog = null; }
  async function go() {
    busy = true;
    startErr = '';
    try {
      const r = await api.start(spec, opts, need ? confirm : '');
      if (!r.ok) { startErr = r.reason || 'The server did not start it.'; return; }
      if (r.unit) fm.beginJob(r.unit, spec, title);
      else { trackDone(title, p.steps.map((s) => s.text)); fm.afterStart(spec.side); }
      close();
    } catch (e) {
      startErr = e.message;
    } finally {
      busy = false;
    }
  }
  const mark = { '+': 'p', '~': 't', '-': 'm' };
  const freeBefore = $derived(spec.toLoc ? spec.toLoc.free : spec.fromLoc?.free);
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && close()} />

<div class="dialog-backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <div class="pdlg" class:danger role="dialog" aria-modal="true" aria-labelledby="fmpt">
    {#if danger}<div class="stripe"></div>{/if}
    <div class="dh">
      {#if !danger}<Halftone cell={3} focus={[1, 0]} reach={0.9} opacity={0.75} />{/if}
      <div class="dtop"><span class="eyebrow" class:bad={danger}>{kicker}</span><span class="grow"></span><Chip>{op}</Chip></div>
      <h3 id="fmpt">{title}</h3>
      <div class="sub mono">{spec.fromLabel}{spec.path !== '/' ? spec.path : ''}{#if spec.to} <i class="ph ph-arrow-right"></i> {spec.toLabel}{spec.toPath !== '/' ? spec.toPath : ''}{/if}</div>
    </div>

    <div class="dbody">
      {#if op === 'rename' || op === 'mkdir'}
        <label class="fld"><span class="eyebrow">{op === 'rename' ? 'New name' : 'Folder name'}</span>
          <input class="input mono" bind:value={opts.newname} autocomplete="off" spellcheck="false" onkeydown={(e) => e.key === 'Enter' && canStart && go()} />
        </label>
        {#if nameBad && opts.newname.trim()}<div class="bad">{nameBad}</div>{/if}
      {/if}

      {#if loadErr}
        <div class="refused"><i class="ph ph-warning-circle"></i>{loadErr}</div>
      {:else if loading && !p}
        <Skeleton lines={3} />
        <div class="lede">Asking the server what would happen…</div>
      {:else if refused}
        <div class="refused"><i class="ph ph-prohibit"></i><div>{p.reason || 'The server refused this.'}<div class="lede" style="margin-top:6px">Nothing has run. The same rule is enforced on the server.</div></div></div>
      {:else if p}
        <div class="facts">
          <div><span class="k">Items</span><span class="v">{things}{Number.isFinite(p.files) ? ` · ${S.plural(p.files, 'file')}` : ''}{Number.isFinite(p.folders) && p.folders ? ` in ${S.plural(p.folders, 'folder')}` : ''}</span></div>
          {#if Number.isFinite(p.bytes)}<div><span class="k">Size</span><span class="v">{S.bytesTxt(p.bytes)}{spec.sum.unknown && !Number.isFinite(p.bytes) ? ' (estimated)' : ''}</span></div>{/if}
          {#if Number.isFinite(p.freeAfter)}<div><span class="k">Free on {op === 'delete' ? spec.fromLabel : spec.toLabel || spec.fromLabel}</span><span class="v">{Number.isFinite(freeBefore) ? `${S.bytesTxt(freeBefore)} → ` : ''}{S.bytesTxt(p.freeAfter)}</span></div>{/if}
        </div>
        <div class="steps">
          {#each p.steps as s}
            <div class="step"><span class="mk {mark[s.mark] ?? 'p'}">{s.mark === '-' ? '−' : s.mark}</span><div class="h">{s.text}</div></div>
          {/each}
          {#each p.notes as n}<div class="step"><span class="mk n">i</span><div class="h dimmed">{n}</div></div>{/each}
          {#each p.warns as w}<div class="step"><span class="mk w">!</span><div class="h">{w}</div></div>{/each}
          {#if p.long}<div class="step"><span class="mk n">…</span><div class="h dimmed">This can take a while. It keeps running if you close the page.</div></div>{/if}
        </div>

        {#if moves}
          <fieldset class="policy">
            <legend class="eyebrow">If a file exists on the target</legend>
            {#each POLICIES as o (o.id)}
              {@const off = o.over && op === 'move'}
              <label class="opt" class:sel={opts.conflict === o.id} class:off use:tip={off ? 'Overwrite is never offered with a move: copy first, then delete the source' : ''}>
                <input type="radio" name="fmpol" value={o.id} bind:group={opts.conflict} disabled={off} />
                <span class="ot"><b>{o.label}</b><span class="os">{o.sub}</span></span>
              </label>
            {/each}
          </fieldset>
          {#if p.conflicts > 0}
            <div class="conf">
              <i class="ph ph-warning"></i><span>{S.plural(p.conflicts, 'item exists', 'items exist')} on the target already.</span>
              <button class="btn sm" onclick={showConflicts}>{showConf ? 'Hide' : 'Show'} the list</button>
            </div>
            {#if showConf}
              {#if confBusy || !confRows}<Skeleton lines={3} />
              {:else if !confRows.length}<div class="lede">The server listed no conflicts.</div>
              {:else}
                <div class="ctable"><table>
                  <thead><tr><th>Path</th><th>Source</th><th>Target</th></tr></thead>
                  <tbody>{#each confRows as c}
                    <tr><td class="mono">{c.path}</td><td>{S.bytesTxt(c.srcBytes)}<br /><span class="dimmed">{S.dateTxt(c.srcMtime)}</span></td><td>{S.bytesTxt(c.dstBytes)}<br /><span class="dimmed">{S.dateTxt(c.dstMtime)}</span></td></tr>
                  {/each}</tbody>
                </table></div>
              {/if}
            {/if}
          {/if}
          <div class="options">
            <label class="chk"><input type="checkbox" bind:checked={() => opts.verify === 'checksum', (v) => (opts.verify = v ? 'checksum' : 'size')} /><span>Verify with checksums <span class="dimmed">(slower; size and time are always checked)</span></span></label>
            {#if op === 'move' && (spec.arrayMove || p.parity)}
              <label class="chk"><input type="checkbox" bind:checked={opts.parity} /><span>Update the parity afterwards <span class="dimmed">(hs pool bulk sync)</span></span></label>
            {/if}
          </div>
        {/if}
      {/if}
      {#if startErr}<div class="refused"><i class="ph ph-warning-circle"></i>{startErr}</div>{/if}
    </div>

    {#if need}
      <div class="confirm">
        <label for="fmcf">Type <code>{need}</code> to confirm</label>
        <input id="fmcf" class="input" bind:value={confirm} placeholder={need} autocomplete="off" spellcheck="false" />
      </div>
    {/if}
    <div class="dfoot">
      <span class="note">{p?.ok ? 'Nothing has run yet. The job appears under Tasks.' : ''}</span>
      <button class="btn" onclick={close}>{p?.ok ? 'Cancel' : 'Close'}</button>
      {#if p?.ok}
        <button class="btn {danger ? 'btn-danger' : 'btn-primary'}" disabled={!canStart} use:tip={canStart ? '' : need && confirm !== need ? 'Type the name to confirm first' : nameBad || (busy ? 'Starting' : 'Not ready yet')} onclick={go}>
          <i class="ph ph-{op === 'delete' ? 'trash' : 'play'}"></i>{busy ? 'Starting…' : verb[op]}
        </button>
      {/if}
    </div>
  </div>
</div>

<style>
  /* the look of shell/PlanDialog.svelte (the same dialog, with the file manager's own body) */
  .pdlg { position: relative; width: min(600px, 100%); max-height: calc(100dvh - 32px); display: flex; flex-direction: column; overflow: hidden; background: var(--panel); border: 1px solid var(--line-2); border-radius: var(--r); box-shadow: 0 24px 64px oklch(0 0 0 / 0.5); }
  .stripe { position: absolute; left: 0; right: 0; top: 0; height: 3px; background: var(--bad); z-index: 2; }
  .dh { position: relative; flex: none; padding: 20px 22px 14px; border-bottom: 1px solid var(--line); overflow: hidden; }
  .pdlg.danger .dh { background: color-mix(in oklch, var(--bad) 10%, var(--panel)); }
  .dtop { position: relative; display: flex; align-items: center; gap: 8px; }
  .eyebrow.bad { color: var(--bad-ink); }
  h3 { position: relative; margin: 6px 0 0; font-size: 18px; font-weight: 600; letter-spacing: -0.02em; }
  .sub { position: relative; margin-top: 4px; font-size: 12px; color: var(--fg-3); overflow-wrap: anywhere; }
  .dbody { padding: 10px 22px 14px; overflow: auto; min-height: 0; display: flex; flex-direction: column; gap: 12px; }
  .lede, .dimmed { font-size: 12.5px; color: var(--fg-3); }
  .bad { color: var(--bad-ink); font-size: 12.5px; }
  .refused { display: flex; gap: 8px; align-items: flex-start; font-size: 13px; color: var(--bad-ink); padding-top: 8px; }
  .fld { display: flex; flex-direction: column; gap: 6px; }
  .facts { display: grid; gap: 4px; padding: 8px 0; border-bottom: 1px solid var(--line); }
  .facts > div { display: flex; gap: 12px; justify-content: space-between; font-size: 12.5px; }
  .k { color: var(--fg-3); }
  .v { text-align: right; color: var(--fg); font-family: var(--mono); }
  .steps { display: flex; flex-direction: column; }
  .step { display: flex; gap: 12px; padding: 9px 0; border-bottom: 1px solid var(--line); }
  .mk { flex: none; width: 22px; height: 22px; display: grid; place-items: center; border: 1px solid var(--line-2); border-radius: var(--r); font: 600 13px var(--mono); color: var(--accent-ink); background: var(--panel-2); }
  .mk.m { color: var(--bad-ink); border-color: color-mix(in oklch, var(--bad) 45%, var(--line-2)); }
  .mk.t { color: var(--info-ink); }
  .mk.w { color: var(--warn-ink); border-color: color-mix(in oklch, var(--warn) 45%, var(--line-2)); }
  .mk.n { color: var(--fg-3); }
  .h { flex: 1; min-width: 0; font-size: 13px; overflow-wrap: anywhere; }
  .policy { margin: 0; padding: 0; border: 0; display: flex; flex-direction: column; gap: 6px; min-width: 0; }
  .policy legend { padding: 0 0 6px; }
  .opt { display: flex; gap: 10px; align-items: flex-start; padding: 8px 10px; border: 1px solid var(--line); cursor: pointer; }
  .opt:hover { border-color: var(--fg-3); }
  .opt.sel { border-color: var(--accent); background: color-mix(in oklch, var(--accent) 8%, transparent); }
  .opt.off { opacity: 0.4; cursor: not-allowed; }
  .ot { display: flex; flex-direction: column; font-size: 13px; }
  .os { font-size: 12px; color: var(--fg-3); }
  .conf { display: flex; align-items: center; gap: 10px; font-size: 12.5px; color: var(--warn-ink); flex-wrap: wrap; }
  .conf .btn { margin-left: auto; }
  .ctable { max-height: 190px; overflow: auto; border: 1px solid var(--line); }
  .ctable table { width: 100%; border-collapse: collapse; font-size: 12px; }
  .ctable th { text-align: left; font: 500 10.5px var(--mono); letter-spacing: 0.06em; text-transform: uppercase; color: var(--fg-3); padding: 6px 8px; position: sticky; top: 0; background: var(--panel-2); }
  .ctable td { padding: 5px 8px; border-top: 1px solid var(--line); vertical-align: top; overflow-wrap: anywhere; }
  .options { display: flex; flex-direction: column; gap: 8px; }
  .chk { display: flex; align-items: flex-start; gap: 10px; font-size: 13px; cursor: pointer; }
  .confirm { padding: 14px 22px; border-top: 1px solid var(--line); }
  .confirm label { display: block; margin-bottom: 6px; font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-3); }
  .confirm code { color: var(--fg); text-transform: none; letter-spacing: 0; }
  .confirm .input { border-color: color-mix(in oklch, var(--bad) 55%, var(--line-2)); font-family: var(--mono); }
  .dfoot { flex: none; display: flex; align-items: center; gap: 8px; justify-content: flex-end; flex-wrap: wrap; padding: 14px 22px; background: var(--panel-2); border-top: 1px solid var(--line); }
  .note { flex: 1; min-width: 180px; color: var(--fg-3); font-size: 12.5px; }
  @media (max-width: 860px) {
    .pdlg { width: calc(100% + 32px); margin: -16px; height: 100dvh; max-height: none; }
    .dh, .dbody, .confirm, .dfoot { padding-left: 16px; padding-right: 16px; }
    .dbody { flex: 1; }
  }
</style>
