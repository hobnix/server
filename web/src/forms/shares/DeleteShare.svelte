<script>
  // Delete: `hs sys shares plan|start <share> delete`. A danger plan: the dialog asks for the share's name before Start.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { share, onclose, ondone = () => {} } = $props();
  const args = () => [share, 'delete'];
</script>

<CreateDialog title="Delete {share}" kicker="Cannot be undone" area="shares" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="warn"><i class="ph ph-warning"></i><span>The share disappears from Samba and from the instances that mount it. Nothing is erased: the folder is renamed to <code>{share}.deleted-&lt;date&gt;</code> and kept. It stays in the “Deleted” list, where you can remove it for good.</span></div>
  {/snippet}
</CreateDialog>

<style>
  .warn { display: flex; gap: 10px; font-size: 13px; color: var(--st-bad); line-height: 1.5; }
  .warn i { font-size: 18px; flex: none; }
  .warn span { color: var(--color-neutral-200); }
</style>
