<script>
  // New share: `hs sys shares plan|start <name> add --kind shares|sensitive [--tier bulk|fast] [--ct <instance> --path <inside> [--as <uid>:<gid>]]`.
  // The command has no switches for backup, cache or snapshots at creation: those are separate changes on the share afterwards.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { Field, TextInput, Select, Checkbox } from '../../ui';

  let { onclose, ondone = () => {} } = $props();

  const cts = poll('/api/sys/ct/list', 15000);
  const instances = $derived(rows(cts).map((r) => r[0]));

  let name = $state('');
  let kind = $state('shares');
  let tier = $state('bulk');
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
    if (tier === 'fast') a.push('--tier', 'fast');
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
    <Field label="Name" error={name && !nameOk ? 'Lowercase letters, digits and “-”, starting with a letter or digit.' : ''}>
      <TextInput bind:value={name} placeholder="photos" autocomplete="off" spellcheck={false} />
    </Field>

    <Field label="Kind" id="ns-kind" help={kind === 'sensitive' ? 'Container-owned data: read-only for the Samba users.' : 'Read and write; everyone acts as adminuser. Only Domain Admins may use it until you set permissions.'}>
      <div class="seg" id="ns-kind">
        <label class="seg-opt"><input type="radio" bind:group={kind} value="shares" /><i class="ph ph-folder"></i>Shared folder</label>
        <label class="seg-opt"><input type="radio" bind:group={kind} value="sensitive" /><i class="ph ph-folder-lock"></i>Sensitive</label>
      </div>
    </Field>

    <Field label="Where" id="ns-tier" help={tier === 'fast' ? 'Fast and small: for app data and files used often.' : 'The big pool of disks: for media, photos and backups.'}>
      <div class="seg" id="ns-tier">
        <label class="seg-opt"><input type="radio" bind:group={tier} value="bulk" /><i class="ph ph-hard-drives"></i>Disks (bulk)</label>
        <label class="seg-opt"><input type="radio" bind:group={tier} value="fast" /><i class="ph ph-lightning"></i>SSD (fast)</label>
      </div>
    </Field>

    <div class="field">
      <Checkbox bind:checked={bind} label="Mount it into an instance" />
    </div>

    {#if bind}
      <Field label="Instance">
        <Select bind:value={ct}>
          <option value="">Choose…</option>
          {#each instances as i}<option value={i}>{i}</option>{/each}
        </Select>
      </Field>
      <Field label="Path inside the instance">
        <TextInput bind:value={path} placeholder="/mnt/photos" autocomplete="off" spellcheck={false} />
      </Field>
      <div class="field">
        <Checkbox bind:checked={mapUser} label="Write as an app user (uid:gid)" hint={mapUser ? 'One such user per instance; the instance restarts when the mapping changes.' : ''} />
        {#if mapUser}
          <div class="row2">
            <TextInput bind:value={asUid} ariaLabel="uid" inputmode="numeric" />
            <span>:</span>
            <TextInput bind:value={asGid} ariaLabel="gid" inputmode="numeric" />
          </div>
        {/if}
      </div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .row2 { display: flex; align-items: center; gap: 8px; margin-top: 8px; max-width: 220px; }
</style>
