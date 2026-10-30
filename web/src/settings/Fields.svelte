<script>
  // The section cards with the editable fields of a list of options (moved from the old pages/Settings.svelte, markup unchanged). `opts` = the
  // options to show (config.svelte.js optsOf, already filtered for the page); a settable key opens the plan first (commit).
  import { tip } from '../ui/tooltip.svelte.js';
  import { drafts, shown, commit, onKey } from './config.svelte.js';

  let { opts = [] } = $props();

  // the sections in the order of the example
  const sections = $derived.by(() => {
    const out = [];
    for (const o of opts) {
      let s = out.find((x) => x.title === o.section);
      if (!s) out.push((s = { title: o.section, fields: [] }));
      s.fields.push(o);
    }
    return out;
  });
</script>

<div class="cols">
  {#each sections as s (s.title)}
    <div class="card elev-sm sec">
      <div class="st">{s.title}</div>
      {#each s.fields as o (o.key)}
        {@const d = drafts[o.key]}
        <div class="fld">
          <div class="k"><code>{o.key}</code></div>
          <div class="v">
            {#if o.settable && o.type === 'bool'}
              <select class="input in" value={shown(o)} onchange={(e) => commit(o, e.currentTarget.value)} aria-label={o.key}>
                <option value="">default ({o.dflt})</option>
                <option value="true">true</option>
                <option value="false">false</option>
              </select>
            {:else if o.settable}
              <input class="input in" value={shown(o)} placeholder={o.dflt} aria-label={o.key} onchange={(e) => commit(o, e.currentTarget.value)} onkeydown={(e) => onKey(e, o)} />
            {:else}
              <input class="input in ro" value={o.cur} placeholder={o.type === 'table' || o.type === 'list' ? '' : o.dflt} readonly aria-label={o.key} />
            {/if}
            <span class="hp" use:tip={o.help}>{o.help}{#if d?.sent} <span class="app">· applying…</span>{/if}</span>
          </div>
        </div>
      {/each}
    </div>
  {/each}
</div>

<style>
  .cols { column-width: 400px; column-gap: 14px; }
  .sec { padding: 14px 16px; gap: 10px; break-inside: avoid; margin-bottom: 14px; }
  .st { font-size: 14px; font-weight: 500; }
  .fld { display: grid; grid-template-columns: 150px minmax(0, 1fr); gap: 12px; align-items: start; }
  .k { padding-top: 7px; overflow-wrap: anywhere; }
  .k code { font-size: 12px; color: var(--color-neutral-200); }
  .v { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .in { min-height: 32px; font-size: 13px; font-family: var(--font-mono, ui-monospace, monospace); }
  .ro { color: var(--color-neutral-300); }
  .hp { font-size: 11.5px; color: var(--color-neutral-500); display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
  .app { color: var(--color-accent-300); }
</style>
