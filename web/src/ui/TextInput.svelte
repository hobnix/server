<script>
  import { getContext } from 'svelte';
  // Native text input with the global .input look. Inside a <Field> it takes id, aria-describedby, aria-invalid and required from it;
  // on its own it needs `ariaLabel`.
  //   <TextInput bind:value={name} placeholder="photos" autocomplete="off" spellcheck={false} />
  // props: value (bindable), type = 'text', id, placeholder, disabled, required, autocomplete, spellcheck, inputmode, ariaLabel, onchange, oninput
  let { value = $bindable(''), type = 'text', id = undefined, placeholder = undefined, disabled = false, required = false, autocomplete = undefined,
        spellcheck = undefined, inputmode = undefined, ariaLabel = undefined, onchange = undefined, oninput = undefined } = $props();
  const f = getContext('field');
  const req = $derived(required || !!f?.required);
</script>

<input class="input" {type} id={id ?? f?.id} bind:value {placeholder} {disabled} required={req || undefined} aria-required={req || undefined}
       {autocomplete} {spellcheck} {inputmode} aria-label={ariaLabel} aria-describedby={f?.describedby} aria-invalid={f?.invalid || undefined}
       {onchange} {oninput} />
