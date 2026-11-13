<script>
  import { setContext } from 'svelte';
  import { describedBy, fieldIds } from './fieldaria.js';
  // A labelled form field: label (with a marked asterisk when required), the control (children), a hint and an error line. The controls
  // (TextInput, Select, Textarea, Checkbox) read the context 'field' and set id, aria-describedby, aria-invalid and aria-required themselves.
  //   <Field label="Name" help="Lowercase letters" error={bad ? 'Not allowed' : ''} required><TextInput bind:value={name} /></Field>
  // props: label, help = '', error = '', required = false, id (default f-<unique>), children
  const uid = $props.id();
  let { label, help = '', error = '', required = false, id = `f-${uid}`, children } = $props();

  const ids = $derived(fieldIds(id));
  setContext('field', {
    get id() { return id; },
    get describedby() { return describedBy(id, { help: !!help, error: !!error }); },
    get invalid() { return !!error; },
    get required() { return required; },
  });
</script>

<div class="field">
  <label for={id}>{label}{#if required}<span aria-hidden="true"> *</span>{/if}</label>
  {@render children?.()}
  {#if help}<div id={ids.help} class="hint">{help}</div>{/if}
  {#if error}<div id={ids.err} class="err" role="alert">{error}</div>{/if}
</div>

<style>
  .hint { font-size: 12px; color: var(--fg-3); }
  .err { font-size: 12px; color: var(--bad); }
</style>
