<script>
  import { getContext } from 'svelte';
  // Native select with the global .input look. Options as data ([{value,label}] or plain strings) or as <option> children. Inside a <Field>
  // it takes id, aria-describedby, aria-invalid and required from it; on its own it needs `ariaLabel`.
  //   <Select bind:value={ct} options={['a', 'b']} />   <Select bind:value={sid}><option value="">Choose...</option>...</Select>
  // props: value (bindable), options, id, disabled, required, ariaLabel, onchange, children
  let { value = $bindable(''), options = undefined, id = undefined, disabled = false, required = false, ariaLabel = undefined,
        onchange = undefined, children = undefined } = $props();
  const f = getContext('field');
  const req = $derived(required || !!f?.required);
  const opts = $derived((options ?? []).map((o) => (typeof o === 'string' ? { value: o, label: o } : o)));
</script>

<select class="input" id={id ?? f?.id} bind:value {disabled} required={req || undefined} aria-required={req || undefined} aria-label={ariaLabel}
        aria-describedby={f?.describedby} aria-invalid={f?.invalid || undefined} {onchange}>
  {#if options}{#each opts as o (o.value)}<option value={o.value}>{o.label}</option>{/each}{/if}
  {@render children?.()}
</select>
