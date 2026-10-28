<script>
  // Get deleted files back from a SnapRAID data disk (hs sys disk plan|start <member> recover [--to <member>] [--types media|all]) and give the disk back
  // to the pool afterwards (<member> recover-finish). The disk leaves /bulk, is made read-only and searched by content (photorec), a long background job;
  // what is found goes onto another data disk (share "recovered"). Names and folders of deleted files cannot be recovered. The server names the word to type.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { pool = 'bulk', member, members = [] } = $props();

  let choice = $state('recover');
  let to = $state('');
  let types = $state('media');

  const targets = $derived(members.filter((n) => n !== member));
  const args = () => (choice === 'finish' ? [member, 'recover-finish'] : [member, 'recover', ...(to ? ['--to', to] : []), '--types', types]);
</script>

<CreateDialog title={choice === 'finish' ? 'Give a disk back to the pool' : 'Recover deleted files'} kicker="Pool" area="disk" {args}>
  {#snippet form()}
    <div class="field">
      <span class="lab">Data disk</span>
      <div class="fixed"><code>{member}</code> <span class="tag tag-neutral" style="padding:1px 7px">{pool}</span></div>
    </div>
    <div class="field">
      <span class="lab">What should happen</span>
      <div class="seg" role="radiogroup" aria-label="Choice">
        <label class="seg-opt"><input type="radio" name="rc-choice" checked={choice === 'recover'} onchange={() => (choice = 'recover')} />Search for deleted files</label>
        <label class="seg-opt"><input type="radio" name="rc-choice" checked={choice === 'finish'} onchange={() => (choice = 'finish')} />Give the disk back to the pool</label>
      </div>
    </div>
    {#if choice === 'recover'}
      <div class="field">
        <span class="lab">Put what is found on</span>
        <select class="input" bind:value={to} aria-label="Target disk">
          <option value="">The disk with the most free space</option>
          {#each targets as t}<option value={t}>{t}</option>{/each}
        </select>
      </div>
      <div class="field">
        <span class="lab">Look for</span>
        <div class="seg" role="radiogroup" aria-label="Types">
          <label class="seg-opt"><input type="radio" name="rc-types" checked={types === 'media'} onchange={() => (types = 'media')} />Photos, videos, music, documents</label>
          <label class="seg-opt"><input type="radio" name="rc-types" checked={types === 'all'} onchange={() => (types = 'all')} />Every kind (slow, many junk files)</label>
        </div>
      </div>
      <div class="hint">The disk leaves /bulk (its files are not visible there meanwhile), is set read-only and is read completely: hours, a background job. Names and folders of deleted files are gone for good; files come back numbered, videos and music named by their tags. A file that was written in pieces can come back cut off. Nothing is ever written to this disk.</div>
    {:else}
      <div class="hint">The disk can be written to again and is mounted into /bulk. What was recovered stays where it is. Refused while the search is still running.</div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
</style>
