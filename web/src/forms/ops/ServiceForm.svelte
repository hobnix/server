<script>
  // Describe a service (hs sys routes plan|start add <name> --port N --container C | --host H ...). Only the description is written; the route on the
  // reverse proxy is made by "Apply" on the Services page. public-ok is red: the typed word is the service name.
  // With `edit` (the name of a described service) the same form changes it: `hs sys routes plan|start edit <name> ...` sends every field, a field
  // left empty is cleared (--clear), what the form does not show (fqdn, scheme, health, other wants) stays in the file.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { onclose, ondone = () => {}, edit = '' } = $props();

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
  let blocked = $state('');
  let auth = $state(false);     // forward auth (authentik) in front of the service
  let wasAuth = false;
  let skip = $state('');        // paths that stay open without login
  let reqHeaders = $state('');  // one header per line, "Name: value"
  let resHeaders = $state('');
  let dashboard = $state(true);
  let proxied = $state(true);   // want reverse-proxy of the file, kept as it is

  // the facts of the service being edited: key, value rows (a dash is empty)
  const cur = poll(() => (edit ? `/api/sys/services/show/${encodeURIComponent(edit)}` : ''), 600000);
  let filled = false;
  $effect(() => {
    if (!edit || filled || !cur.loaded) return;
    const v = Object.fromEntries(rows(cur).map((r) => [r[0], r[1] === '-' ? '' : (r[1] ?? '')]));
    if (!v.name) return;
    filled = true;
    name = v.name; where = v.where || 'container';
    if (where === 'container') ct = v.machine; else host = v.machine;
    port = v.port; title = v.title; names = v.names === v.name ? '' : v.names;
    exposure = v.exposure || 'private-ok'; paths = v.public_paths.split(',').join(' ');
    blocked = v.blocked_paths.split(',').join(' '); skip = v.auth_skip.split(',').join(' ');
    auth = wasAuth = v.auth === 'authentik';
    reqHeaders = v.request_headers.split(' | ').join('
'); resHeaders = v.response_headers.split(' | ').join('
');
    const want = v.want.split(',');
    dashboard = want.includes('dashboard'); proxied = want.includes('reverse-proxy');
  });

  const args = () => {
    if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(name)) return null;
    if (edit && !filled) return null;
    if (!/^[0-9]{1,5}$/.test(port) || +port < 1 || +port > 65535) return null;
    const a = [edit ? 'edit' : 'add', name, '--port', port];
    if (where === 'container') { if (!ct) return null; a.push('--container', ct); }
    else { if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$/.test(host.trim())) return null; a.push('--host', host.trim()); }
    if (title.trim()) a.push('--title', title.trim());
    else if (edit) a.push('--clear', 'title');
    const n = names.replace(/\s+/g, '');
    if (n) { if (!/^[a-z0-9][a-z0-9,-]{0,100}$/.test(n)) return null; a.push('--names', n); }
    else if (edit) a.push('--clear', 'names');
    a.push('--exposure', exposure);
    const ps = paths.split(/[\s,]+/).filter(Boolean);
    for (const p of ps) {
      if (!/^\/[A-Za-z0-9._/-]{0,100}$/.test(p)) return null;
      a.push('--public-path', p);
    }
    if (!ps.length && edit) a.push('--clear', 'public-path');
    const list = (text, opt, clear, re, sep) => {
      const items = text.split(sep).map((x) => x.trim()).filter(Boolean);
      for (const x of items) { if (!re.test(x)) return false; a.push(opt, x); }
      if (!items.length && clear) a.push('--clear', clear);
      return true;
    };
    const pathRe = /^\/[A-Za-z0-9._/-]{0,100}$/, headRe = /^[A-Za-z0-9-]{1,64}: [ -~]{1,200}$/;
    if (!list(blocked, '--blocked-path', edit && 'blocked-path', pathRe, /[\s,]+/)) return null;
    if (auth) a.push('--auth', 'authentik');
    else if (edit && wasAuth) a.push('--auth', 'none');
    if (!list(skip, '--auth-skip', null, pathRe, /[\s,]+/)) return null;
    if (!list(reqHeaders, '--request-header', edit && 'request-header', headRe, '
')) return null;
    if (!list(resHeaders, '--response-header', edit && 'response-header', headRe, '
')) return null;
    if (edit) a.push('--want', [proxied && 'reverse-proxy', dashboard && 'dashboard'].filter(Boolean).join(',') || 'none');
    else a.push('--want', dashboard ? 'reverse-proxy,dashboard' : 'reverse-proxy');
    return a;
  };
</script>

<CreateDialog title={edit ? 'Change ' + edit : 'Describe a service'} kicker="Services" area="routes" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="sv-name">Name</label>
      <input id="sv-name" class="input" bind:value={name} readonly={!!edit} placeholder="wiki" maxlength="41" autocomplete="off" />
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
    <div class="field">
      <label for="sv-blocked">Blocked paths (optional)</label>
      <input id="sv-blocked" class="input" bind:value={blocked} placeholder="/admin /metrics" autocomplete="off" />
    </div>
    <label class="check"><input type="checkbox" bind:checked={auth} /> Login first (forward auth with authentik)</label>
    {#if auth}
      <div class="field">
        <label for="sv-skip">Paths without login (optional)</label>
        <input id="sv-skip" class="input" bind:value={skip} placeholder="/hook /api/public" autocomplete="off" />
      </div>
    {/if}
    <div class="field">
      <label for="sv-reqh">Request headers (optional, one per line)</label>
      <textarea id="sv-reqh" class="input" rows="2" bind:value={reqHeaders} placeholder="X-Forwarded-Prefix: /wiki"></textarea>
    </div>
    <div class="field">
      <label for="sv-resh">Response headers (optional, one per line)</label>
      <textarea id="sv-resh" class="input" rows="2" bind:value={resHeaders} placeholder="X-Frame-Options: SAMEORIGIN"></textarea>
    </div>
    <label class="check"><input type="checkbox" bind:checked={dashboard} /> Show a tile on the dashboard</label>
  {/snippet}
</CreateDialog>

<style>
  .check { display: flex; gap: 8px; align-items: center; font-size: 12.5px; color: var(--color-neutral-300); }
</style>
