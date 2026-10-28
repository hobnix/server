<script>
  // Add something that runs out on a date: hs sys expiry plan|start add <name> --date YYYY-MM-DD [--renew <text>]
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone } = $props();

  let name = $state('');
  let date = $state('');
  let renew = $state('');

  // the plan answers "needs date" while the date is empty, and refuses a name or a date the script does not accept
  const args = () => {
    const n = name.trim();
    if (!n) return null;
    const a = ['add', n];
    if (date) a.push('--date', date);
    if (renew.trim()) a.push('--renew', renew.trim());
    return a;
  };
</script>

<CreateDialog title="New expiry date" kicker="Add" area="expiry" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="ex-name">What runs out</label>
      <input id="ex-name" class="input" bind:value={name} placeholder="Domain controller certificate" maxlength="61" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="ex-date">Until when</label>
      <input id="ex-date" class="input" type="date" bind:value={date} />
    </div>
    <div class="field">
      <label for="ex-renew">How it is renewed (a hint for you, optional)</label>
      <input id="ex-renew" class="input" bind:value={renew} placeholder="Cloudflare dashboard, Zero Trust, Tunnels" maxlength="120" autocomplete="off" />
    </div>
    <div class="hint">The health check warns 30 days and 7 days before the date. A name that is on the list already gets the new date.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
