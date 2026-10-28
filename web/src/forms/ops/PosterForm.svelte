<script>
  // Draw a poster (hs sys ext posters plan|start generate --eyebrow <text> --title <text> [--color c] [--seed n] [--case keep]).
  // The picture is kept on the server and shown on the Posters page.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone } = $props();

  const COLORS = ['red', 'orange', 'yellow', 'green', 'teal', 'blue', 'indigo', 'purple', 'pink'];
  let eyebrow = $state('');
  let title = $state('');
  let color = $state('');
  let seed = $state('');
  let keepCase = $state(false);

  const args = () => {
    const e = eyebrow.trim(), t = title.trim();
    if (!e || !t || e.length > 80 || t.length > 80) return null;
    if (seed && !/^[0-9]{1,9}$/.test(seed.trim())) return null;
    const a = ['generate', '--eyebrow', e, '--title', t];
    if (color) a.push('--color', color);
    if (seed.trim()) a.push('--seed', seed.trim());
    if (keepCase) a.push('--case', 'keep');
    return a;
  };
</script>

<CreateDialog title="New poster" kicker="Posters" area="ext/posters" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="po-eyebrow">Small line above the title</label>
      <input id="po-eyebrow" class="input" bind:value={eyebrow} placeholder="Movie night" maxlength="80" autocomplete="off" />
    </div>
    <div class="field">
      <label for="po-title">Title</label>
      <input id="po-title" class="input" bind:value={title} placeholder="Dune" maxlength="80" autocomplete="off" />
    </div>
    <div class="field">
      <label for="po-color">Colour</label>
      <select id="po-color" class="input" bind:value={color}>
        <option value="">Made up from the seed</option>
        {#each COLORS as c}<option value={c}>{c}</option>{/each}
      </select>
    </div>
    <div class="field">
      <label for="po-seed">Seed (optional)</label>
      <input id="po-seed" class="input" bind:value={seed} placeholder="a number: the same seed gives the same poster" inputmode="numeric" maxlength="9" autocomplete="off" />
    </div>
    <label class="check"><input type="checkbox" bind:checked={keepCase} /> Keep upper and lower case (the default is all capitals)</label>
  {/snippet}
</CreateDialog>

<style>
  .check { display: flex; gap: 8px; align-items: center; font-size: 12.5px; color: var(--color-neutral-300); }
</style>
