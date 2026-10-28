<script>
  // One custom trigger and a hard-edged popover instead of a native <select>. Closes on Esc, a click outside or a pick; focus returns to the trigger.
  // Keyboard (the part the design left open): on the trigger Enter, Space, ArrowDown/Up open it; in the list ArrowUp/ArrowDown move, Home/End jump,
  // Enter/Space pick, Esc closes, Tab closes and moves on; typing letters jumps to the next option that starts with them (type-ahead, 700 ms buffer).
  //   <Combobox options={[{ value: 'a', label: 'All' }, 'Urgent only']} bind:value placeholder="Priority" />
  // options: strings or { value, label, disabled? }. `wide` = full width form field. `onchange(value)` fires after a pick.
  let { options = [], value = $bindable(''), placeholder = 'Choose…', wide = false, disabled = false, label = '', onchange = null, id = undefined } = $props();

  const opts = $derived(options.map((o) => (typeof o === 'object' ? o : { value: o, label: o })));
  const current = $derived(opts.find((o) => o.value === value));

  let open = $state(false);
  let active = $state(0);
  let trigger, list;
  let pos = $state({ left: 0, top: 0, minWidth: 0, maxHeight: 280 });
  let buf = '', bufTimer;
  const uid = `cmb-${Math.random().toString(36).slice(2, 8)}`;

  function place() {
    const r = trigger.getBoundingClientRect();
    const below = innerHeight - r.bottom - 12, above = r.top - 12;
    const up = below < 180 && above > below;
    pos = { left: Math.max(8, Math.min(r.left, innerWidth - 8 - Math.max(r.width, 160))), minWidth: r.width, maxHeight: Math.min(280, up ? above : below),
            top: up ? undefined : r.bottom + 4, bottom: up ? innerHeight - r.top + 4 : undefined };
  }
  function show() {
    if (disabled || open) return;
    place();
    active = Math.max(0, opts.findIndex((o) => o.value === value));
    open = true;
    queueMicrotask(() => { list?.focus(); list?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' }); });
  }
  function close(refocus = true) {
    if (!open) return;
    open = false;
    if (refocus) trigger?.focus();
  }
  function pick(i) {
    const o = opts[i];
    if (!o || o.disabled) return;
    value = o.value;
    onchange?.(o.value);
    close();
  }
  function move(d) {
    let i = active;
    for (let n = 0; n < opts.length; n++) {
      i = (i + d + opts.length) % opts.length;
      if (!opts[i].disabled) break;
    }
    active = i;
    list?.querySelector(`#${uid}-${i}`)?.scrollIntoView({ block: 'nearest' });
  }
  function typeahead(ch) {
    clearTimeout(bufTimer);
    buf += ch.toLowerCase();
    bufTimer = setTimeout(() => (buf = ''), 700);
    const n = opts.length;
    // a repeated single letter cycles; a longer buffer searches from the current option
    const start = buf.length === 1 ? active + 1 : active;
    for (let k = 0; k < n; k++) {
      const i = (start + k) % n;
      if (!opts[i].disabled && String(opts[i].label).toLowerCase().startsWith(buf)) { active = i; list?.querySelector(`#${uid}-${i}`)?.scrollIntoView({ block: 'nearest' }); return; }
    }
  }
  function ontriggerkey(e) {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp' || e.key === 'Enter' || e.key === ' ') { e.preventDefault(); show(); }
  }
  function onlistkey(e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
    else if (e.key === 'Home') { e.preventDefault(); active = 0; }
    else if (e.key === 'End') { e.preventDefault(); active = opts.length - 1; }
    else if (e.key === 'Enter' || (e.key === ' ' && !buf)) { e.preventDefault(); pick(active); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
    else if (e.key === 'Tab') close(false);
    else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) { e.preventDefault(); typeahead(e.key); }
  }
</script>

<svelte:window onresize={() => open && close(false)} />

<button type="button" {id} class="cmbtn" class:wide bind:this={trigger} {disabled} aria-haspopup="listbox" aria-expanded={open} aria-label={label || undefined}
        aria-controls={open ? `${uid}-list` : undefined} onclick={() => (open ? close() : show())} onkeydown={ontriggerkey}>
  <span class="cv-l" class:empty={!current}>{current ? current.label : placeholder}</span><span class="cv"></span>
</button>

{#if open}
  <button type="button" class="ddscrim" tabindex="-1" aria-hidden="true" onclick={() => close(false)}></button>
  <div class="cmpop" id="{uid}-list" role="listbox" tabindex="-1" bind:this={list} aria-activedescendant="{uid}-{active}"
       style:left="{pos.left}px" style:top={pos.top !== undefined ? pos.top + 'px' : undefined} style:bottom={pos.bottom !== undefined ? pos.bottom + 'px' : undefined}
       style:min-width="{pos.minWidth}px" style:max-height="{pos.maxHeight}px" onkeydown={onlistkey}>
    {#each opts as o, i (o.value)}
      <div class="cmopt" id="{uid}-{i}" role="option" tabindex="-1" aria-selected={o.value === value} aria-disabled={o.disabled || undefined} class:act={i === active} class:dis={o.disabled}
           onpointermove={() => (active = i)} onclick={() => pick(i)} onkeydown={() => {}}>{o.label}</div>
    {/each}
  </div>
{/if}

<style>
  .cmbtn { display: inline-flex; align-items: center; justify-content: space-between; gap: 10px; min-width: 112px; height: 30px; padding: 0 10px; border: 1px solid var(--line-2); border-radius: var(--r); background: var(--panel-2); color: var(--fg); font-size: 12.5px; text-align: left; }
  .cmbtn.wide { display: flex; width: 100%; height: 36px; padding: 0 12px; font-size: inherit; }
  .cmbtn:hover { border-color: var(--fg-3); }
  .cmbtn[aria-expanded='true'] { border-color: var(--accent); }
  .cmbtn:disabled { opacity: 0.45; cursor: not-allowed; }
  .cv-l { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .cv-l.empty { color: var(--fg-3); }
  .cv { flex: none; width: 6px; height: 6px; border: solid var(--fg-3); border-width: 0 1.5px 1.5px 0; transform: rotate(45deg) translate(-2px, -2px); }
  .cmbtn[aria-expanded='true'] .cv { transform: rotate(225deg) translate(-2px, -2px); border-color: var(--accent-ink); }
  .ddscrim { position: fixed; inset: 0; z-index: 60; padding: 0; border: 0; background: transparent; cursor: default; }
  .cmpop { position: fixed; z-index: 61; overflow: auto; padding: 4px; background: var(--panel); border: 1px solid var(--line-2); border-radius: var(--r); box-shadow: var(--shadow); outline: none; }
  .cmopt { display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 12px 0 8px; color: var(--fg-2); font-size: 12.5px; white-space: nowrap; cursor: pointer; }
  .cmopt::before { content: ''; flex: none; width: 6px; height: 6px; }
  .cmopt.act { background: var(--panel-2); color: var(--fg); }
  .cmopt[aria-selected='true'] { background: color-mix(in oklch, var(--accent) 17%, transparent); color: var(--fg); font-weight: 500; }
  .cmopt[aria-selected='true']::before { background: var(--accent-ink); }
  .cmopt.dis { opacity: 0.4; cursor: not-allowed; }
  .cmpop:focus-visible .cmopt.act { outline: 2px solid var(--accent); outline-offset: -2px; }
</style>
