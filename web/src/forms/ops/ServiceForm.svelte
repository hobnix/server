<script>
  // Describe a service (hs sys routes plan|start add <name> --port N --container C | --host H ...). Only the description is written; the route on the
  // reverse proxy is made by "Apply" on the Services page. public-ok is red: the typed word is the service name.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { onclose, ondone = () => {} } = $props();

  const cts = poll('/api/sys/ct/list', 15000);
  const instances = $derived(rows(cts).map((r) => r[0]));

  let name = $state('');
  let where = $state('container');
  let ct = $state('');
  let host = $state('');
  let port = $state('');
  let title = $state('');
  let names = $state('');
  let exposure = $state('private-ok');
  let paths = $state('');
  let dashboard = $state(true);

  const args = () => {
    if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(name)) return null;
    if (!/^[0-9]{1,5}$/.test(port) || +port < 1 || +port > 65535) return null;
    const a = ['add', name, '--port', port];
    if (where === 'container') { if (!ct) return null; a.push('--container', ct); }
    else { if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$/.test(host.trim())) return null; a.push('--host', host.trim()); }
    if (title.trim()) a.push('--title', title.trim());
    const n = names.replace(/\s+/g, '');
    if (n) { if (!/^[a-z0-9][a-z0-9,-]{0,100}$/.test(n)) return null; a.push('--names', n); }
    a.push('--exposure', exposure);
    for (const p of paths.split(/[\s,]+/).filter(Boolean)) {
      if (!/^\/[A-Za-z0-9._/-]{0,100}$/.test(p)) return null;
      a.push('--public-path', p);
    }
    a.push('--want', dashboard ? 'reverse-proxy,dashboard' : 'reverse-proxy');
    return a;
  };
</script>

<CreateDialog title="Describe a service" kicker="Services" area="routes" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="sv-name">Name</label>
      <input id="sv-name" class="input" bind:value={name} placeholder="wiki" maxlength="41" autocomplete="off" />
    </div>
    <div class="field">
      <label for="sv-where">Runs on</label>
      <select id="sv-where" class="input" bind:value={where}>
        <option value="container">An instance of this server</option>
        <option value="host">Another machine (name or address)</option>
      </select>
    </div>
    {#if where === 'container'}
      <div class="field">
        <label for="sv-ct">Instance</label>
        <select id="sv-ct" class="input" bind:value={ct}>
          <option value="">Choose…</option>
          {#each instances as i}<option value={i}>{i}</option>{/each}
        </select>
      </div>
    {:else}
      <div class="field">
        <label for="sv-host">Host</label>
        <input id="sv-host" class="input" bind:value={host} placeholder="10.10.95.40" autocomplete="off" />
      </div>
    {/if}
    <div class="field">
      <label for="sv-port">Port</label>
      <input id="sv-port" class="input" bind:value={port} placeholder="3000" inputmode="numeric" maxlength="5" autocomplete="off" />
    </div>
    <div class="field">
      <label for="sv-title">Title (optional)</label>
      <input id="sv-title" class="input" bind:value={title} placeholder="Wiki" maxlength="160" autocomplete="off" />
    </div>
    <div class="field">
      <label for="sv-names">Host names (optional)</label>
      <input id="sv-names" class="input" bind:value={names} placeholder="wiki,notes: the name of the service when empty" autocomplete="off" />
    </div>
    <div class="field">
      <label for="sv-exp">Exposure</label>
      <select id="sv-exp" class="input" bind:value={exposure}>
        <option value="private-ok">private-ok: only inside (the default)</option>
        <option value="never-public">never-public: refused on a public proxy</option>
        <option value="public-ok">public-ok: may be put on the internet</option>
      </select>
    </div>
    <div class="field">
      <label for="sv-paths">Public paths (optional)</label>
      <input id="sv-paths" class="input" bind:value={paths} placeholder="/hook /api/public" autocomplete="off" />
    </div>
    <label class="check"><input type="checkbox" bind:checked={dashboard} /> Show a tile on the dashboard</label>
  {/snippet}
</CreateDialog>

<style>
  .check { display: flex; gap: 8px; align-items: center; font-size: 12.5px; color: var(--color-neutral-300); }
</style>
