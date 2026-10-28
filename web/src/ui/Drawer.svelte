<script>
  // The side drawer of a list page: header (name, chip, state, close), optional tabs, a body, an action row. 400 px wide next to the list
  // (put it in a <Split>); full screen on a phone (up to 860 px). Esc closes it when the focus is inside.
  //   <Drawer title={row.name} chip="zfs" state="ok" stateLabel="online" tabs={[{ id: 'info', label: 'Info' }, { id: 'snap', label: 'Snapshots' }]} bind:tab onclose={() => (sel = null)}>
  //     <Kv items={[{ k: 'Size', v: '4 TB' }]} /> ... {#snippet actions()}<button class="btn sm">Scrub</button>{/snippet}
  //   </Drawer>
  // `tabs` empty = no tab row. The body snippet receives the active tab id: {#snippet children(tab)} ... {/snippet} (or ignore it).
  import { tr } from "../i18n.js";
  import StatusDot from './StatusDot.svelte';
  import Chip from './Chip.svelte';
  let { title = '', chip = '', state = '', stateLabel = '', tabs = [], tab = $bindable(''), onclose = null, children, actions, header } = $props();
  const active = $derived(tab || tabs[0]?.id || '');
  let root;
  $effect(() => { root?.focus({ preventScroll: true }); });
</script>

<aside class="sdr xh" bind:this={root} tabindex="-1" aria-label={title} onkeydown={(e) => e.key === 'Escape' && onclose && (e.stopPropagation(), onclose())}>
  <div class="sdh">
    <div class="ttl">
      <b class="nm">{title}</b>
      {#if chip}<Chip>{chip}</Chip>{/if}
      {#if state}<StatusDot {state} label={stateLabel} />{/if}
      {@render header?.()}
    </div>
    {#if onclose}<button class="btn btn-ghost btn-icon sq" aria-label="Close" onclick={onclose}><i class="ph ph-x"></i></button>{/if}
  </div>
  {#if tabs.length}
    <div class="stabs" role="tablist">
      {#each tabs as t (t.id)}
        <button class="stab" class:on={active === t.id} role="tab" aria-selected={active === t.id} onclick={() => (tab = t.id)}>{tr(t.label)}</button>
      {/each}
    </div>
  {/if}
  <div class="body">{@render children?.(active)}</div>
  {#if actions}<div class="arow">{@render actions()}</div>{/if}
</aside>

<style>
  .sdr { width: 400px; flex: none; position: sticky; top: 0; align-self: flex-start; max-height: 100%; display: flex; flex-direction: column; background: var(--panel); border: 1px solid var(--line); box-shadow: var(--shadow); outline: none; }
  .sdh { display: flex; align-items: center; gap: 10px; padding: 14px 16px; border-bottom: 1px solid var(--line); }
  .ttl { flex: 1; min-width: 0; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .nm { font-size: 15px; font-weight: 600; letter-spacing: -0.01em; overflow: hidden; text-overflow: ellipsis; }
  .sq { width: 30px; min-height: 30px; }
  .stabs { display: flex; gap: 2px; padding: 0 10px; border-bottom: 1px solid var(--line); overflow-x: auto; overflow-y: hidden; }
  .stab { position: relative; flex: none; height: 38px; padding: 0 12px; border: 0; background: none; color: var(--fg-2); font-weight: 500; }
  .stab:hover, .stab.on { color: var(--fg); }
  .stab.on::after { content: ''; position: absolute; left: 8px; right: 8px; bottom: 0; height: 2px; background: linear-gradient(90deg, var(--h2), var(--h1), var(--h4)); }
  .body { overflow: auto; min-height: 0; flex: 1; }
  .arow { display: flex; flex-wrap: wrap; gap: 8px; padding: 14px 16px; border-top: 1px solid var(--line); }
  @media (max-width: 1100px) { .sdr { width: 100%; position: static; } }
  @media (max-width: 860px) { .sdr { position: fixed; inset: 52px 0 0 0; z-index: 13; width: auto; max-height: none; box-shadow: none; } .sdr::before, .sdr::after { display: none; } }
</style>
