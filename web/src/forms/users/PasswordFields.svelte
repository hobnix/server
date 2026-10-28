<script>
  // Two password fields (the second must match, at least 8 characters). The password lives only in these inputs and in the form's state; the form hands it
  // to CreateDialog as `stdin`, so it travels in the request body and never in an argument, a URL or the page text.
  let { pw = $bindable(''), pw2 = $bindable('') } = $props();
  const short = $derived(pw.length > 0 && pw.length < 8);
  const mismatch = $derived(pw2.length > 0 && pw !== pw2);
</script>

<div class="field">
  <label for="pw1">Password</label>
  <input id="pw1" class="input" type="password" bind:value={pw} autocomplete="new-password" />
  <div class="hint" class:bad={short}>At least 8 characters. The domain's password rules (complexity) apply as well; the job says if it is refused.</div>
</div>
<div class="field">
  <label for="pw2">Repeat the password</label>
  <input id="pw2" class="input" type="password" bind:value={pw2} autocomplete="new-password" />
  {#if mismatch}<div class="hint bad">The two passwords differ.</div>{/if}
</div>

<style>
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 4px; }
  .hint.bad { color: var(--st-bad); }
</style>
