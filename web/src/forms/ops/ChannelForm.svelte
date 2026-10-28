<script>
  // Add or change a notification channel: hs sys notify plan|start add <name> --provider <p> ... | set <name> ...
  // The fields of a provider come from `sys notify providers` (provider, key, label, kind, required|optional, pattern, caps). The one secret of a
  // provider (a topic address, an SMTP password) is the one line on standard input: it never goes into an argument or a log, and it is not shown again.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone, providers = [], channel = null } = $props();

  const CLASSES = [['alarm', 'Alarms'], ['status', 'Status'], ['heartbeat', 'Heartbeat'], ['digest', 'Digest']];
  const PRIOS = ['min', 'low', 'default', 'high', 'urgent'];
  const editing = !!channel;                       // [name, provider, enabled, minprio, quiet, outside, source, ready, categories, caps]
  const names = [...new Set(providers.map((r) => r[0]))];

  let name = $state(channel?.[0] ?? '');
  let provider = $state(channel?.[1] ?? names[0] ?? '');
  let minprio = $state(channel?.[3] ?? 'min');
  let quiet = $state(channel?.[4] ?? 'respect');
  let cats = $state(new Set((channel?.[8] ?? 'alarm,status,digest').split(',')));
  let values = $state({});                         // key -> text; a secret too (never leaves this form except as stdin)

  const fields = $derived(providers.filter((r) => r[0] === provider).map((r) => ({ key: r[1], label: r[2], secret: r[3] === 'secret', required: r[4] === 'required' })));
  const caps = $derived(new Set((providers.find((r) => r[0] === provider)?.[6] ?? 'alarm,status,digest').split(',')));
  const secretField = $derived(fields.find((f) => f.secret));

  const toggle = (c) => { const s = new Set(cats); s.has(c) ? s.delete(c) : s.add(c); cats = s; };
  const order = (s) => CLASSES.map((c) => c[0]).filter((c) => s.has(c) && caps.has(c)).join(',');

  const args = () => {
    const n = name.trim();
    if (!n || !provider) return null;
    const a = editing ? ['set', n] : ['add', n, '--provider', provider];
    a.push('--min-priority', minprio, '--quiet', quiet);
    const c = order(cats);
    if (c) a.push('--categories', c);
    for (const f of fields) {
      const v = (values[f.key] ?? '').trim();
      if (!v) continue;
      if (f.secret) a.push('--secret', f.key);
      else a.push('--set', `${f.key}=${v}`);
    }
    return a;
  };
  const stdin = () => {
    const v = secretField ? (values[secretField.key] ?? '').trim() : '';
    return v || undefined;
  };
</script>

<CreateDialog title={editing ? `Channel ${channel[0]}` : 'New notification channel'} kicker="Notifications" area="notify" {args} {stdin} {onclose} {ondone}>
  {#snippet form()}
    {#if !editing}
      <div class="field">
        <label for="nc-name">Name</label>
        <input id="nc-name" class="input" bind:value={name} placeholder="phone" maxlength="31" autocomplete="off" spellcheck="false" />
      </div>
      <div class="field">
        <label for="nc-prov">Provider</label>
        <select id="nc-prov" class="input" bind:value={provider}>
          {#each names as p}<option value={p}>{p}</option>{/each}
        </select>
      </div>
    {/if}
    {#each fields as f (provider + f.key)}
      <div class="field">
        <label for="nc-{f.key}">{f.label}{f.required ? '' : ' (optional)'}{editing ? ' - leave empty to keep it' : ''}</label>
        <input id="nc-{f.key}" class="input" type={f.secret ? 'password' : 'text'} bind:value={values[f.key]} autocomplete={f.secret ? 'new-password' : 'off'} spellcheck="false" />
      </div>
    {/each}
    <div class="field">
      <label for="nc-min">Lowest priority it gets</label>
      <select id="nc-min" class="input" bind:value={minprio}>{#each PRIOS as p}<option value={p}>{p}</option>{/each}</select>
    </div>
    <div class="field">
      <label for="nc-quiet">Quiet hours</label>
      <select id="nc-quiet" class="input" bind:value={quiet}>
        <option value="respect">respect: low messages wait and come as one digest</option>
        <option value="ignore">ignore: always at once (for a mailbox or a feed)</option>
      </select>
    </div>
    <div class="field">
      <span class="lbl">What it carries</span>
      <div class="cl">
        {#each CLASSES as [c, label]}
          <label class="chk" class:off={!caps.has(c)}><input type="checkbox" checked={cats.has(c) && caps.has(c)} disabled={!caps.has(c)} onchange={() => toggle(c)} />{label}</label>
        {/each}
      </div>
    </div>
    <div class="hint">The secret stays on the server (root only) and is not shown again. A channel that is a service on this server says nothing while the storage is locked: keep one outside.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--color-neutral-500); }
  .lbl { font-size: 12px; color: var(--color-neutral-400); }
  .cl { display: flex; gap: 14px; flex-wrap: wrap; }
  .chk { display: flex; gap: 6px; align-items: center; font-size: 12.5px; color: var(--color-neutral-300); }
  .chk.off { opacity: 0.45; }
</style>
