<script>
  // Step "Name and kind" of the instance wizard (CreateInstance.svelte). The same step for a container, Docker and a virtual machine.
  let { name = $bindable(''), type = $bindable('container') } = $props();
  const kinds = [['container', 'Empty container'], ['docker', 'Docker'], ['vm', 'Virtual machine']];
</script>

<div class="field">
  <label for="ci-name">Name</label>
  <input id="ci-name" class="input" bind:value={name} placeholder="e.g. jellyfin" autocomplete="off" spellcheck="false" />
</div>
<div class="field">
  <label for="ci-kind">Kind</label>
  <div id="ci-kind" class="seg" role="radiogroup">
    {#each kinds as [v, l]}
      <label class="seg-opt"><input type="radio" name="ci-type" value={v} bind:group={type} />{l}</label>
    {/each}
  </div>
</div>
{#if type === 'vm'}<div class="hint">A virtual machine reserves its memory and disk. Without sizes it gets 2048 MiB, 2 cores and 20 GiB.</div>{/if}

<style>
  .hint { font-size: 12px; color: var(--fg-3); }
</style>
