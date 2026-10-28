<script>
  // Replace a member of a pool with a free disk (hs sys pool plan|start <pool> replace --member <name> --disks <id> ...).
  // SnapRAID can format the new disk with another filesystem or LUKS; ZFS takes the disk as it is.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import DiskPicker from './DiskPicker.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { freeDisks, FS } from './disks.js';

  let { pool, member, snap = false } = $props();

  let picked = $state([]);
  let fs = $state('ext4');
  let encrypt = $state(false);
  let pass = $state('');

  const free = poll('/api/sys/pool/disks', 15000);
  const disks = $derived(freeDisks(rows(free)));

  const args = () => {
    if (!picked.length) return null;
    if (!snap) return [pool, 'replace', '--member', member, '--disks', picked[0]];
    if (encrypt && !pass) return null;
    return [pool, 'replace', '--member', member, '--disks', picked[0], '--fs', fs, ...(encrypt ? ['--encrypt'] : [])];
  };
  const stdin = () => (snap && encrypt && pass ? pass : undefined);
</script>

<CreateDialog title="Replace a disk" kicker="Pool" area="pool" {args} {stdin}>
  {#snippet form()}
    <div class="field">
      <span class="lab">Member to replace</span>
      <div class="fixed"><code>{member}</code> <span class="tag tag-neutral" style="padding:1px 7px">{pool}</span></div>
    </div>
    <div class="field">
      <label for="rp-disks">New disk (it is erased)</label>
      <div id="rp-disks"><DiskPicker {disks} loaded={free.loaded} bind:picked single /></div>
    </div>
    {#if snap}
      <div class="field">
        <label for="rp-fs">Filesystem of the new disk</label>
        <select id="rp-fs" class="input" bind:value={fs}>
          {#each FS as [v, t]}<option value={v}>{t}</option>{/each}
        </select>
      </div>
      <label class="check"><input type="checkbox" bind:checked={encrypt} />Encrypt with LUKS</label>
      {#if encrypt}
        <div class="field">
          <label for="rp-pass">Passphrase (the one for all encrypted disks of this server)</label>
          <input id="rp-pass" class="input" type="password" bind:value={pass} autocomplete="new-password" spellcheck="false" />
          <div class="hint">It is sent to the server on its own and never appears in the command.</div>
        </div>
      {/if}
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .check { display: flex; align-items: center; gap: 8px; font-size: 13.5px; cursor: pointer; }
  .check input { accent-color: var(--color-accent); }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
  select.input { cursor: pointer; }
</style>
