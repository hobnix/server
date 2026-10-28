<script>
  // Make a free disk the backup disk (hs sys backup plan|start init --disk <by-id name>). The disk is ERASED: the plan is red and the server
  // names the word to type (the kernel name of the disk, like sdc). The backup password is made inside the vault and is NOT shown here:
  // read it once on the server (sudo cat /var/lib/hs/restic-password) and keep it in your password manager.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import DiskPicker from '../storage/DiskPicker.svelte';
  import { freeDisks } from '../storage/disks.js';
  import { poll, rows } from '../../data.svelte.js';

  let { onclose, ondone } = $props();

  const free = poll('/api/sys/pool/disks', 15000);
  const disks = $derived(freeDisks(rows(free)));
  let picked = $state([]);

  const args = () => (picked.length ? ['init', '--disk', picked[0]] : null);
</script>

<CreateDialog title="Set up the backup disk" kicker="Backup" area="backup" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <span class="lab">Disk (it is erased)</span>
      <DiskPicker {disks} loaded={free.loaded} bind:picked single empty="No free disk. Plug the backup disk in; a disk that belongs to a pool is never offered." />
    </div>
    <div class="hint">
      The disk is formatted ext4 with the label <code>backup</code>, the backup repository is made on it and a password is created in the vault.
      After it has run, read the password once on the server (<code>sudo cat /var/lib/hs/restic-password</code>) and keep it in your password manager:
      without it a backup cannot be opened, also not after the system disk dies.
    </div>
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
