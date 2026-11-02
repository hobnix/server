<script>
  // Editor for one web-managed Compose app: name (new only), compose text, and the write-only env table.
  import { get } from '../../api.js';
  import { openPlan } from '../../ui.svelte.js';

  let { app = '', rev: revProp = 'new', doc: docProp = null, onclose = () => {} } = $props();

  const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]{0,63}$/;
  const APP_RE = /^[a-z0-9][a-z0-9_-]{0,40}$/;
  const template = 'services:\n  app:\n    image: nginx:alpine\n    env_file: .env\n';

  let name = $state(app);
  let rev = $state(revProp);
  let compose = $state(docProp?.compose ?? template);
  let existing = $state((docProp?.env ?? []).map((n) => ({ name: n, value: '', remove: false })));
  let added = $state([]);
  let newName = $state('');
  let loading = $state(!!app && !docProp);
  let loadError = $state('');
  let formError = $state('');

  $effect(() => { rev = revProp; });
  $effect(() => {
    if (docProp) {
      compose = docProp.compose ?? compose;
      existing = (docProp.env ?? []).map((n) => ({ name: n, value: '', remove: false }));
      added = [];
    }
  });

  async function load() {
    const target = app || name;
    if (!target) return;
    loading = true;
    loadError = '';
    try {
      const d = await get(`/api/sys/docker/app/${encodeURIComponent(target)}`);
      rev = d.rev;
      compose = d.compose;
      existing = (d.env ?? []).map((n) => ({ name: n, value: '', remove: false }));
      added = [];
    } catch (e) {
      loadError = e.message || 'Could not load the app.';
    } finally {
      loading = false;
    }
  }

  if (app && !docProp) load();

  function addRow() {
    const n = newName.trim();
    if (!n) return;
    if (!NAME_RE.test(n)) { formError = `Invalid env name: ${n}`; return; }
    if (existing.some((r) => r.name === n) || added.some((r) => r.name === n)) { formError = `Duplicate env name: ${n}`; return; }
    added = [...added, { name: n, value: '' }];
    newName = '';
    formError = '';
  }

  function validate() {
    const names = new Set();
    for (const r of existing) {
      if (r.remove && r.value !== '') return `Env ${r.name}: cannot both set and remove.`;
      if (names.has(r.name)) return `Duplicate env name: ${r.name}.`;
      names.add(r.name);
    }
    for (const r of added) {
      if (!NAME_RE.test(r.name)) return `Invalid env name: ${r.name}.`;
      if (names.has(r.name)) return `Duplicate env name: ${r.name}.`;
      names.add(r.name);
    }
    if (names.size > 200) return 'Too many env names (max 200).';
    return '';
  }

  function buildDocument() {
    const set = {};
    const remove = [];
    for (const r of existing) {
      if (r.remove) remove.push(r.name);
      else if (r.value !== '') set[r.name] = r.value;
    }
    for (const r of added) {
      set[r.name] = r.value;
    }
    return { compose, set, remove };
  }

  function save() {
    formError = validate();
    if (formError) return;
    const target = app || name;
    if (!target || !APP_RE.test(target)) { formError = 'Invalid app name.'; return; }
    if (compose.length > 262144) { formError = 'Compose file is too large.'; return; }
    const document = buildDocument();
    openPlan('docker-app', [target, 'app-save', '--rev', rev], `save ${target}`, { document, onReload: load });
  }
</script>

<div class="editor">
  {#if loading}
    <div class="dim">Loading…</div>
  {:else}
    {#if loadError}<div class="err">{loadError}</div>{/if}
    {#if formError}<div class="err">{formError}</div>{/if}
    {#if !app}
      <label class="field">Name
        <input class="input" bind:value={name} placeholder="my-app" />
      </label>
    {:else}
      <div class="field"><span class="lbl">Name</span><code>{app}</code></div>
    {/if}
    <label class="field">Compose file
      <textarea class="compose" bind:value={compose} spellcheck="false"></textarea>
    </label>
    <div class="env">
      <div class="envhead">
        <span>Environment (.env)</span>
        <span class="hint">values are write-only and never shown again</span>
      </div>
      <table class="envtbl">
        <thead><tr><th>Name</th><th>Value</th><th>Remove</th></tr></thead>
        <tbody>
          {#each existing as r, i}
            <tr>
              <td><code>{r.name}</code></td>
              <td><input class="input" type="password" bind:value={r.value} placeholder="set: leave empty to keep" disabled={r.remove} /></td>
              <td><input type="checkbox" bind:checked={r.remove} onchange={() => { if (r.remove) r.value = ''; }} /></td>
            </tr>
          {/each}
          {#each added as r, i}
            <tr>
              <td><code>{r.name}</code></td>
              <td><input class="input" type="password" bind:value={r.value} /></td>
              <td><button class="btn btn-ghost btn-sm" onclick={() => { added = added.filter((_, j) => j !== i); }}>remove row</button></td>
            </tr>
          {/each}
        </tbody>
      </table>
      <div class="addrow">
        <input class="input" bind:value={newName} placeholder="NEW_NAME" />
        <button class="btn btn-ghost btn-sm" onclick={addRow}>Add</button>
      </div>
    </div>
    <div class="actions">
      <button class="btn" onclick={onclose}>Close</button>
      <button class="btn btn-primary" onclick={save}>Save</button>
    </div>
  {/if}
</div>

<style>
  .editor { display: flex; flex-direction: column; gap: 12px; padding: 12px 16px; }
  .field { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--fg-3); }
  .lbl { font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; }
  .compose { min-height: 220px; font: 12px/1.5 var(--mono); }
  .envtbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
  .envtbl th, .envtbl td { padding: 4px 6px; border-bottom: 1px solid var(--line); }
  .addrow { display: flex; gap: 8px; margin-top: 8px; }
  .actions { display: flex; justify-content: flex-end; gap: 8px; }
  .err { color: var(--bad-ink); font-size: 12.5px; }
  .dim { color: var(--fg-3); font-size: 12.5px; }
  .hint { font-size: 11px; color: var(--fg-3); margin-left: 8px; }
</style>