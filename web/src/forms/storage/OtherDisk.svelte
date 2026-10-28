<script>
  // Another disk (USB, hot-plug) with data on it: `hs sys disk plan|start <partition> temp-mount [--name <n>]` mounts it read-only and shares it
  // (only Domain Admins at first), `<name> temp-copy --to <share>` copies everything on it into a share (a background job), `<name> temp-eject`
  // removes the share and unmounts. The disk itself is never formatted or written. The list is `hs sys temp-disk raw`:
  // device|fs|label|bytes|mountpoints per partition (system, pool, swap and backup disks are never offered).
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { sizeTxt } from '../../pages/storage/pool.js';

  let { onclose, ondone = () => {} } = $props();

  const raw = poll('/api/sys/temp-disk/raw', 10000);
  const sharesRead = poll('/api/sys/shares/overview', 60000);
  const shares = $derived(rows(sharesRead).map((r) => r[0]).filter((n) => /^[a-z0-9][a-z0-9-]{0,40}$/.test(n ?? '')));

  const TEMP = /^\/mnt\/temp\/([a-z0-9][a-z0-9-]{0,31})$/;
  // the list has one cell per row (fields joined by |)
  const parts = $derived(rows(raw).map((r) => r.join('\t').split('|')).filter((p) => p.length >= 5).map((p) => {
    const mp = p[4].split(',').map((m) => TEMP.exec(m)).find(Boolean);
    return { dev: p[0].replace(/^\/dev\//, ''), fs: p[1], label: p[2], bytes: Number(p[3]), mounted: !!p[4], temp: mp ? mp[1] : '' };
  }));

  let dev = $state('');
  let action = $state('mount');
  let name = $state('');
  let to = $state('');
  const sel = $derived(parts.find((p) => p.dev === dev) ?? parts[0]);
  // a free partition can only be mounted; a mounted one is copied or ejected (one that is mounted elsewhere is left alone)
  const act = $derived(!sel ? '' : !sel.mounted ? 'mount' : sel.temp ? (action === 'copy' ? 'copy' : 'eject') : '');
  const nameOk = $derived(name === '' || /^[a-z0-9][a-z0-9-]{0,31}$/.test(name));
  const args = () => {
    if (!sel || !act) return null;
    if (act === 'mount') return nameOk ? [sel.dev, 'temp-mount', ...(name ? ['--name', name] : [])] : null;
    if (act === 'eject') return [sel.temp, 'temp-eject'];
    return to ? [sel.temp, 'temp-copy', '--to', to] : null;
  };
  const label = (p) => `${p.dev} · ${p.fs}${p.label ? ` “${p.label}”` : ''} · ${sizeTxt(p.bytes)}${p.mounted ? (p.temp ? ' · mounted here' : ' · mounted elsewhere') : ''}`;
</script>

<CreateDialog title="Other disk" kicker="Disk" area="disk" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="od-dev">Disk</label>
      {#if parts.length}
        <select id="od-dev" class="input" value={sel?.dev} onchange={(e) => { dev = e.currentTarget.value; action = 'copy'; }}>
          {#each parts as p}<option value={p.dev}>{label(p)}</option>{/each}
        </select>
      {:else}
        <div class="hint">{raw.loaded ? (raw.error ? 'The disks could not be read.' : 'No other disk found: plug it in, this list updates by itself.') : 'Loading…'}</div>
      {/if}
    </div>
    {#if sel && !sel.mounted}
      <div class="field">
        <label for="od-name">Name of the share (optional)</label>
        <input id="od-name" class="input" bind:value={name} placeholder={sel.label || sel.dev} autocomplete="off" spellcheck="false" />
        {#if !nameOk}<div class="err">Lower-case letters, digits and hyphens.</div>{/if}
      </div>
      <div class="hint">Mounted read-only and shared as <code>temp-name</code> for Domain Admins. Nothing on the disk is changed.</div>
    {:else if sel?.temp}
      <div class="field">
        <span class="lab">What to do</span>
        <div class="seg" role="radiogroup" aria-label="Action">
          <label class="seg-opt"><input type="radio" name="od-act" checked={act === 'copy'} onchange={() => (action = 'copy')} />Copy into a share</label>
          <label class="seg-opt"><input type="radio" name="od-act" checked={act === 'eject'} onchange={() => (action = 'eject')} />Eject</label>
        </div>
      </div>
      {#if act === 'copy'}
        <div class="field">
          <label for="od-to">Copy everything into the share</label>
          <select id="od-to" class="input" bind:value={to}>
            <option value="">Choose a share…</option>
            {#each shares as s}<option value={s}>{s}</option>{/each}
          </select>
        </div>
        <div class="hint">Runs as a background job; it checks first that there is room.</div>
      {:else}
        <div class="hint">The share is removed and the disk unmounted. Afterwards it is safe to unplug.</div>
      {/if}
    {:else if sel}
      <div class="hint">This partition is mounted somewhere this page does not manage.</div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .err { font-size: 12px; color: var(--st-bad); margin-top: 4px; }
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
