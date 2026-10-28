<script>
  // New share: `hs sys shares plan|start <name> add --kind shares|sensitive [--ct <instance> --path <inside> [--as <uid>:<gid>]]`.
  // The command has no switches for backup, cache or snapshots at creation: those are separate changes on the share afterwards.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { onclose, ondone = () => {} } = $props();

  const cts = poll('/api/sys/ct/list', 15000);
  const instances = $derived(rows(cts).map((r) => r[0]));

  let name = $state('');
  let kind = $state('shares');
  let bind = $state(false);
  let ct = $state('');
  let path = $state('');
  let mapUser = $state(false);
  let asUid = $state('1000');
  let asGid = $state('1000');

  const nameOk = $derived(/^[a-z0-9][a-z0-9-]{0,40}$/.test(name));
  const args = () => {
    if (!nameOk) return null;
    const a = [name, 'add', '--kind', kind];
    if (bind) {
      if (!ct) return null;
      a.push('--ct', ct);
      if (path) a.push('--path', path);
      else return null;
      if (mapUser && /^[0-9]{1,7}$/.test(asUid) && /^[0-9]{1,7}$/.test(asGid)) a.push('--as', `${asUid}:${asGid}`);
    }
    return a;
  };
</script>

<CreateDialog title="New share" area="shares" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="ns-name">Name</label>
      <input id="ns-name" class="input" bind:value={name} placeholder="photos" autocomplete="off" spellcheck="false" />
      {#if name && !nameOk}<div class="err">Lowercase letters, digits and “-”, starting with a letter or digit.</div>{/if}
    </div>

    <div class="field">
      <label for="ns-kind">Kind</label>
      <div class="seg" id="ns-kind">
        <label class="seg-opt"><input type="radio" bind:group={kind} value="shares" /><i class="ph ph-folder"></i>Shared folder</label>
        <label class="seg-opt"><input type="radio" bind:group={kind} value="sensitive" /><i class="ph ph-folder-lock"></i>Sensitive</label>
      </div>
      <div class="hint">{kind === 'sensitive' ? 'Container-owned data: read-only for the Samba users.' : 'Read and write; everyone acts as adminuser. Only Domain Admins may use it until you set permissions.'}</div>
    </div>

    <div class="field">
      <label class="chk"><input type="checkbox" bind:checked={bind} />Mount it into an instance</label>
    </div>

    {#if bind}
      <div class="field">
        <label for="ns-ct">Instance</label>
        <select id="ns-ct" class="input" bind:value={ct}>
          <option value="">Choose…</option>
          {#each instances as i}<option value={i}>{i}</option>{/each}
        </select>
      </div>
      <div class="field">
        <label for="ns-path">Path inside the instance</label>
        <input id="ns-path" class="input" bind:value={path} placeholder="/mnt/photos" autocomplete="off" spellcheck="false" />
      </div>
      <div class="field">
        <label class="chk"><input type="checkbox" bind:checked={mapUser} />Write as an app user (uid:gid)</label>
        {#if mapUser}
          <div class="row2">
            <input class="input" aria-label="uid" bind:value={asUid} inputmode="numeric" />
            <span>:</span>
            <input class="input" aria-label="gid" bind:value={asGid} inputmode="numeric" />
          </div>
          <div class="hint">One such user per instance; the instance restarts when the mapping changes.</div>
        {/if}
      </div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .err { font-size: 12px; color: var(--st-bad); margin-top: 4px; }
  .hint { font-size: 12px; color: var(--color-neutral-500); margin-top: 6px; }
  .chk { display: inline-flex; align-items: center; gap: 8px; font-size: 14px; cursor: pointer; margin-bottom: 0 !important; }
  .row2 { display: flex; align-items: center; gap: 8px; margin-top: 8px; max-width: 220px; }
</style>
