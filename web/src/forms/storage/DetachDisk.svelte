<script>
  // Take a SnapRAID data disk out of /bulk to work on it by hand, and put it back (hs sys disk plan|start <member> detach|attach).
  // While a disk is part of /bulk its files and the pool's are the same files: copying from the disk into /bulk (a file manager, mv, Midnight Commander) truncates them.
  // A detached disk is not in the pool, so copying from it is an ordinary copy. Its files are missing in /bulk meanwhile; the health check complains after 2 hours.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { pool = 'bulk', member } = $props();

  let choice = $state('detach');
  const args = () => [member, choice];
</script>

<CreateDialog title={choice === 'attach' ? 'Put a disk back into the pool' : 'Detach a disk'} kicker="Pool" area="disk" {args}>
  {#snippet form()}
    <div class="field">
      <span class="lab">Data disk</span>
      <div class="fixed"><code>{member}</code> <span class="tag tag-neutral" style="padding:1px 7px">{pool}</span></div>
    </div>
    <div class="field">
      <span class="lab">What should happen</span>
      <div class="seg" role="radiogroup" aria-label="Choice">
        <label class="seg-opt"><input type="radio" name="dt-choice" checked={choice === 'detach'} onchange={() => (choice = 'detach')} />Take it out of /bulk</label>
        <label class="seg-opt"><input type="radio" name="dt-choice" checked={choice === 'attach'} onchange={() => (choice = 'attach')} />Put it back</label>
      </div>
      <div class="hint">
        {#if choice === 'detach'}The disk leaves /bulk, so you can copy from it with any tool: a detached disk is not part of the pool. Its files are missing in /bulk until you put it back. To move folders between disks use the move button, to empty a disk use Close with move.
        {:else}The disk is mounted into /bulk again and its files are shown there again. Refused while something still uses it.{/if}
      </div>
    </div>
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
</style>
