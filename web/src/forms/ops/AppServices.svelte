<script>
  // Where the services of an app can be reached (hs sys routes plan|start set <service> [--local yes|no] [--public yes|no] [--public-name <fqdn>]).
  // Local = a name on the gateway proxy (capability gateway), public = a route on the reverse proxy. Only the description is changed; the
  // routes are made by "Apply" on the Services page. Public is red (the typed word is the service name); an admin page is never public.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import Switch from '../../ui/Switch.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { ui } from '../../ui.svelte.js';

  let { app, cts = [], onclose, ondone = () => {} } = $props();

  const read = poll('/api/sys/services/app', 15000);
  const gateway = $derived(Array.isArray(ui.features.capabilities) && ui.features.capabilities.includes('gateway'));
  const dash = (v) => (v === '-' || v === undefined ? '' : v);

  // services app: name, container, title, local, public, fqdn, exposure, admin
  const mine = $derived(rows(read)
    .map((r) => ({ name: r[0], ct: dash(r[1]), title: dash(r[2]) || r[0], local: r[3] === 'yes', pub: r[4] === 'yes', fqdn: dash(r[5]), exposure: r[6], admin: r[7] === 'yes' }))
    .filter((s) => cts.includes(s.ct)));

  let pick = $state('');
  let local = $state(false);
  let pub = $state(false);
  let fqdn = $state('');
  const sel = $derived(mine.find((s) => s.name === pick) ?? mine[0]);
  $effect(() => {   // the form starts from what the chosen service has now
    if (sel) { local = sel.local; pub = sel.pub; fqdn = sel.fqdn; }
  });

  const changed = $derived(sel && (local !== sel.local || pub !== sel.pub || (pub && fqdn !== sel.fqdn)));
  const args = () => {
    if (!sel || !changed) return null;
    const a = ['set', sel.name];
    if (gateway && local !== sel.local) a.push('--local', local ? 'yes' : 'no');
    if (pub !== sel.pub || (pub && fqdn !== sel.fqdn)) {
      if (pub && !/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/.test(fqdn.trim())) return null;
      a.push('--public', pub ? 'yes' : 'no');
      if (pub) a.push('--public-name', fqdn.trim());
    }
    return a;
  };
</script>

<CreateDialog title="Services of {app}" kicker="Apps" area="routes" {args} {onclose} {ondone}>
  {#snippet form()}
    {#if !read.loaded}
      <div class="hint">Reading the services…</div>
    {:else if !mine.length}
      <div class="hint">{app} has not described a service yet. Run it again from the Apps page, or describe one on the Services page.</div>
    {:else}
      {#if mine.length > 1}
        <div class="field">
          <label for="as-svc">Service</label>
          <select id="as-svc" class="input" bind:value={pick}>
            {#each mine as s}<option value={s.name}>{s.title} ({s.name})</option>{/each}
          </select>
        </div>
      {/if}
      <div class="row">
        <Switch bind:checked={local} disabled={!gateway} reason="The gateway extension is not on, so there are no local names" label="Local" />
        <div><b>Local</b><span>A name inside your network, through the gateway proxy.</span></div>
      </div>
      <div class="row">
        <Switch bind:checked={pub} disabled={sel?.admin} reason="An admin page is never public" label="Public" />
        <div><b>Public</b><span>Reachable from the internet through the reverse proxy.</span></div>
      </div>
      {#if pub && !sel?.admin}
        <div class="field">
          <label for="as-name">Public name</label>
          <input id="as-name" class="input" bind:value={fqdn} placeholder="media.example.org" autocomplete="off" spellcheck="false" />
        </div>
      {/if}
      <div class="hint">This changes the description only. Nothing reaches the proxies until you press Apply on the Services page.</div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--fg-3); }
  .row { display: flex; gap: 12px; align-items: center; padding: 8px 0; }
  .row b { display: block; font-size: 13px; }
  .row span { font-size: 12px; color: var(--fg-3); }
</style>
