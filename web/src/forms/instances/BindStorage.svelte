<script>
  // Bind storage to an instance: `ct <name> add-storage --kind fast|shares|sensitive --name <storage> --path <inside> [--readonly] [--as uid:gid]`
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { ct, ondone = () => {} } = $props();
  let kind = $state('shares');
  let sname = $state('');
  let path = $state('');
  let readonly = $state(false);
  let as = $state('');

  const kinds = [['shares', 'Share'], ['sensitive', 'Sensitive share'], ['fast', 'Fast volume']];
  const args = () => {
    if (!sname.trim() || !path.trim()) return null;
    const a = [ct, 'add-storage', '--kind', kind, '--name', sname.trim(), '--path', path.trim()];
    if (readonly) a.push('--readonly');
    if (as.trim()) a.push('--as', as.trim());
    return a;
  };
</script>

<CreateDialog kicker="Storage" title={`Bind storage to ${ct}`} area="ct" {args} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="bs-kind">Kind</label>
      <div id="bs-kind" class="seg" role="radiogroup">
        {#each kinds as [v, l]}
          <label class="seg-opt"><input type="radio" name="bs-kind" value={v} bind:group={kind} />{l}</label>
        {/each}
      </div>
    </div>
    <div class="field">
      <label for="bs-name">{kind === 'fast' ? 'Volume name' : 'Share name'}</label>
      <input id="bs-name" class="input" bind:value={sname} placeholder="media" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="bs-path">Path inside the instance</label>
      <input id="bs-path" class="input" bind:value={path} placeholder="/media" autocomplete="off" spellcheck="false" />
    </div>
    <label class="chk"><input type="checkbox" bind:checked={readonly} />Read only</label>
    <div class="field">
      <label for="bs-as">App user inside (uid:gid, optional)</label>
      <input id="bs-as" class="input" bind:value={as} placeholder="1000:1000" autocomplete="off" spellcheck="false" />
    </div>
  {/snippet}
</CreateDialog>

<style>
  .chk { display: flex; align-items: center; gap: 8px; font-size: 14px; cursor: pointer; accent-color: var(--color-accent); }
</style>
