<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // One row of the resource tree: indent guides, caret, icon, label, chip, count, then ONE right-hand slot for a lock or a status dot. A dimmed row
  // (storage locked) shows the lock in that slot. The row is a real link (middle click, copy address work); a plain click calls `onclick`.
  //   <TreeRow depth={1} icon="database" label="Storage" href="/node/hs/storage" active caret="open" ontoggle={...} count="3" dot={{ state: 'ok', title: 'online' }} />
  import StatusDot from '../ui/StatusDot.svelte';
  import { tr } from "../i18n.js";
  let {
    depth = 0, caret = null, icon = '', label = '', href = '#', active = false, dim = false, strong = false, gap = false,
    chip = '', count = '', warn = false, dot = null, lock = false, title = '',
    onclick = null, ontoggle = null, onhover = null,
  } = $props();

  function click(e) {
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;   // let the browser open it in a tab
    e.preventDefault();
    onclick?.(e);
  }
</script>

<div class="trow" class:active class:dim class:gap role="treeitem" aria-selected={active} aria-expanded={caret ? caret === 'open' : undefined} aria-level={depth + 1}>
  {#each Array(depth) as _}<span class="g"></span>{/each}
  {#if caret}
    <button use:tip={caret === 'open' ? 'Collapse' : 'Expand'} class="caret" aria-label={caret === 'open' ? 'Collapse' : 'Expand'} tabindex="-1" onclick={(e) => { e.stopPropagation(); ontoggle?.(); }}>
      <i class="ph ph-caret-{caret === 'open' ? 'down' : 'right'}" style="font-size:11px"></i>
    </button>
  {:else}<span class="cs"></span>{/if}
  <a class="tlink" {href} use:tip={title} aria-current={active ? 'page' : undefined} onclick={click} onpointerenter={onhover} onfocus={onhover}>
    {#if icon}<i class="ph ph-{icon}" style="font-size:15px"></i>{/if}
    <span class="lbl" class:strong>{tr(label)}</span>
    {#if chip}<span class="chip">{chip}</span>{/if}
    <span class="rt">
      {#if count !== ''}<span class="cnt" class:warn>{count}</span>{/if}
      <span class="sl">
        {#if lock}<i class="ph ph-lock-simple" style="font-size:12px;color:var(--fg-3)" use:tip={'Storage locked'}></i>
        {:else if dot}<StatusDot bare state={dot.state} label={dot.title} />{/if}
      </span>
    </span>
  </a>
</div>

<style>
  .trow { display: flex; align-items: center; height: 30px; border-radius: var(--r); position: relative; }
  .trow.gap { margin-top: 10px; }
  .trow:hover { background: var(--panel-2); }
  .trow.active { background: color-mix(in oklch, var(--accent) 17%, transparent); }
  .trow.active .tlink { color: var(--fg); font-weight: 500; }
  .trow.active .tlink i { color: var(--accent-ink); }
  .trow.dim .tlink { opacity: 0.45; }
  .g { align-self: stretch; flex: none; width: 14px; margin-left: 5px; border-left: 1px solid var(--line); }
  .caret { flex: none; width: 20px; height: 24px; display: grid; place-items: center; border: 0; border-radius: var(--r); background: none; color: var(--fg-3); padding: 0; }
  .caret:hover { background: var(--panel-3); color: var(--fg); }
  .cs { flex: none; width: 20px; }
  .tlink { flex: 1; min-width: 0; height: 100%; display: flex; align-items: center; gap: 8px; padding: 0 8px 0 2px; color: var(--fg-2); text-decoration: none; }
  .tlink i { flex: none; color: var(--fg-3); }
  .lbl { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .lbl.strong { font-weight: 600; color: var(--fg); }
  .chip { flex: none; font: 500 10px var(--mono); text-transform: uppercase; letter-spacing: 0.06em; padding: 0 5px; border: 1px solid var(--line-2); color: var(--fg-3); }
  .rt { margin-left: auto; display: flex; align-items: center; gap: 8px; }
  .sl { flex: none; width: 16px; display: grid; place-items: center; }
  .cnt { font: 500 11px var(--mono); color: var(--fg-2); background: var(--panel-3); padding: 0 6px; min-width: 18px; text-align: center; white-space: nowrap; }
  .cnt.warn { color: var(--warn-ink); }
</style>
