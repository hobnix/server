<script>
  import { getContext } from 'svelte';
  import { describedBy, fieldIds } from './fieldaria.js';
  // Native checkbox with a visible label; the whole label is clickable. `hint` is a grey line below; inside a <Field> the field's
  // description is used too. (Switch box is the button-drawn variant for table cells; this one is for forms.)
  //   <Checkbox bind:checked={bind} label="Mount it into an instance" hint="Optional" />
  // props: checked (bindable), label (or children), hint = '', id, disabled, onchange
  let { checked = $bindable(false), label = '', hint = '', id = undefined, disabled = false, onchange = undefined, children = undefined } = $props();
  const f = getContext('field');
  const uid = $props.id();
  const own = $derived(id ?? `cb-${uid}`);
  const hintId = $derived(fieldIds(own).help);
  const desc = $derived([hint ? describedBy(own, { help: true }) : '', f?.describedby ?? ''].filter(Boolean).join(' ') || undefined);
</script>

<div class="cb">
  <label class="row" class:off={disabled} for={own}>
    <input type="checkbox" id={own} bind:checked {disabled} aria-describedby={desc} aria-invalid={f?.invalid || undefined} {onchange} />
    <span>{#if children}{@render children()}{:else}{label}{/if}</span>
  </label>
  {#if hint}<div id={hintId} class="hint">{hint}</div>{/if}
</div>

<style>
  .row { display: inline-flex; align-items: center; gap: 8px; font-size: 14px; color: var(--fg); cursor: pointer; }
  .row.off { opacity: 0.5; cursor: not-allowed; }
  input { margin: 0; accent-color: var(--accent); cursor: inherit; }
  input:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .hint { font-size: 12px; color: var(--fg-3); margin-top: 4px; }
</style>
