<script>
  // Format (erase) a disk that belongs to nothing (hs sys disk plan|start <disk> wipe). The plan is red and the server names the word to type (the disk).
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { sizeTxt } from '../../pages/storage/pool.js';

  let { disk, model = '', size = 0 } = $props();

  const args = () => [disk, 'wipe'];
</script>

<CreateDialog title="Format a disk" kicker="Disks" area="disk" {args}>
  {#snippet form()}
    <div class="field">
      <span class="lab">Disk</span>
      <div class="fixed"><code>{disk}</code>{#if model || size} <span class="tag tag-neutral" style="padding:1px 7px">{[model, size ? sizeTxt(size) : ''].filter(Boolean).join(' · ')}</span>{/if}</div>
    </div>
    <div class="hint">Erases every filesystem and the partition table, so the disk is empty and can be added to a pool. A disk that is mounted, in a pool or an array, or one of this server's encrypted disks is refused.</div>
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
</style>
