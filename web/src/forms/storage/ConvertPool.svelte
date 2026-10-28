<script>
  // Convert a SnapRAID data disk (hs sys pool plan|start bulk convert --member <name> [--fs ext4|xfs|btrfs] [--encrypt]):
  // its files move onto the other data disks, the disk is erased and formatted again (another filesystem, or LUKS).
  // It is red and long (a background job); the server names the word to type (the disk). Only the data disks of a SnapRAID bulk pool qualify.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { FS } from './disks.js';

  let { pool = 'bulk', member: member0 = '', members = [] } = $props();

  let member = $state(member0 || members[0] || '');
  let fs = $state('ext4');
  let encrypt = $state(false);
  let pass = $state('');

  const args = () => {
    if (!member || (encrypt && !pass)) return null;
    return [pool, 'convert', '--member', member, '--fs', fs, ...(encrypt ? ['--encrypt'] : [])];
  };
  const stdin = () => (encrypt && pass ? pass : undefined);
</script>

<CreateDialog title="Convert a disk" kicker="Pool" area="pool" {args} {stdin}>
  {#snippet form()}
    <div class="field">
      <label for="cv-member">Data disk</label>
      {#if members.length > 1}
        <select id="cv-member" class="input" bind:value={member}>
          {#each members as m}<option value={m}>{m}</option>{/each}
        </select>
      {:else}
        <div class="fixed" id="cv-member"><code>{member}</code> <span class="tag tag-neutral" style="padding:1px 7px">{pool}</span></div>
      {/if}
      <div class="hint">Its files move onto the other data disks first (that can take hours, it runs as a background job), then the disk is erased and formatted again. The parity follows with the next sync.</div>
    </div>
    <div class="field">
      <label for="cv-fs">New filesystem</label>
      <select id="cv-fs" class="input" bind:value={fs}>
        {#each FS as [v, t]}<option value={v}>{t}</option>{/each}
      </select>
    </div>
    <label class="check"><input type="checkbox" bind:checked={encrypt} />Encrypt with LUKS</label>
    {#if encrypt}
      <div class="field">
        <label for="cv-pass">Passphrase (the one for all encrypted disks of this server; the first time it sets it)</label>
        <input id="cv-pass" class="input" type="password" bind:value={pass} autocomplete="new-password" spellcheck="false" />
        <div class="hint">It is sent to the server on its own and never appears in the command.</div>
      </div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .check { display: flex; align-items: center; gap: 8px; font-size: 13.5px; cursor: pointer; }
  .check input { accent-color: var(--color-accent); }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
  select.input { cursor: pointer; }
</style>
