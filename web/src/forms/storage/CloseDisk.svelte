<script>
  // Stop (or allow again) new files on a SnapRAID data disk (hs sys pool plan|start bulk close|open --member <name> [--drain]).
  // A closed disk stays in /bulk and keeps its files; mergerfs just never picks it for a new file. --drain also moves its files
  // onto the other disks (a long background job, the server names the word to type). Open and close without drain change a mark only.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { pool = 'bulk', member, closed = false } = $props();

  let choice = $state(closed ? 'open' : 'close');

  const args = () => (choice === 'open' ? [pool, 'open', '--member', member] : [pool, 'close', '--member', member, ...(choice === 'drain' ? ['--drain'] : [])]);
</script>

<CreateDialog title={closed ? 'Closed disk' : 'No new files on a disk'} kicker="Pool" area="pool" {args}>
  {#snippet form()}
    <div class="field">
      <span class="lab">Data disk</span>
      <div class="fixed"><code>{member}</code> <span class="tag tag-neutral" style="padding:1px 7px">{pool}</span></div>
    </div>
    <div class="field">
      <span class="lab">What should happen</span>
      <div class="seg" role="radiogroup" aria-label="Choice">
        {#if closed}
          <label class="seg-opt"><input type="radio" name="cl-choice" checked={choice === 'open'} onchange={() => (choice = 'open')} />Take new files again</label>
        {:else}
          <label class="seg-opt"><input type="radio" name="cl-choice" checked={choice === 'close'} onchange={() => (choice = 'close')} />No new files</label>
        {/if}
        <label class="seg-opt"><input type="radio" name="cl-choice" checked={choice === 'drain'} onchange={() => (choice = 'drain')} />{closed ? 'Move its files away' : 'No new files, and move its files away'}</label>
      </div>
      <div class="hint">
        {#if choice === 'open'}New files are spread over all disks again, this one included.
        {:else if choice === 'close'}The disk stays in /bulk and keeps what it holds; only new files go to the other disks. Nothing moves, nothing is erased. A file that already lives there and grows is still written there.
        {:else}Its files move onto the other data disks (hours, a background job). Until a file is moved it is not visible in /bulk. The disk stays in the pool, empty and closed. A good first step before removing it.{/if}
      </div>
    </div>
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
</style>
