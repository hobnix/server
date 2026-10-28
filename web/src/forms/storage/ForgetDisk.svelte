<script>
  // Remove a missing disk from the inventory for good (hs sys disk plan|start <serial> forget). The plan is red and the server names the word to type (the serial).
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { serial, model = '', dev = '' } = $props();

  const args = () => [serial, 'forget'];
</script>

<CreateDialog title="Forget a missing disk" kicker="Disks" area="disk" {args}>
  {#snippet form()}
    <div class="field">
      <span class="lab">Disk</span>
      <div class="fixed"><code>{serial}</code>{#if model || dev} <span class="tag tag-neutral" style="padding:1px 7px">{[model, dev ? `was ${dev}` : ''].filter(Boolean).join(' · ')}</span>{/if}</div>
    </div>
    <div class="hint">Takes the disk off the list of disks this server has had, together with its SMART history and events. Only a disk that is not in the machine can be forgotten; if it comes back it is recorded as a new one.</div>
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
</style>
