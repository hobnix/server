<script>
  // The preset step: one preset or none (Skip keeps everything minimal). Capabilities are shown but cannot be chosen yet.
  import ChoiceList from '../ui/ChoiceList.svelte';
  import Checkbox from '../ui/Checkbox.svelte';
  import Chip from '../ui/Chip.svelte';
  import { poll, rows } from '../data.svelte.js';
  import { openPlan } from '../ui.svelte.js';
  let { save = $bindable(null) } = $props();
  const list = poll('/api/sys/preset/list', 60000);
  const parts = poll('/api/sys/parts/list', 60000);
  // preset list: name, title, description, capabilities; parts list: name, on, kind, nix, switch, title
  const presets = $derived(rows(list).map((r) => ({ id: r[0], label: r[1], text: r[2] === '-' ? '' : r[2] })));
  const caps = $derived(rows(parts).map((r) => ({ name: r[0], title: r[5] || r[0] })));
  let picked = $state('');
  // true: nothing chosen, advance; false: a plan was opened
  save = () => {
    const p = presets.find((x) => x.id === picked);
    if (!p) return true;
    openPlan('preset', ['apply', p.id], 'Apply the preset ' + p.label);
    return false;
  };
</script>

<ChoiceList options={presets} value={picked} onpick={(id) => (picked = id)} label="Preset" />
{#if caps.length}
  <div class="muted">Single capabilities</div>
  {#each caps as c (c.name)}
    <Checkbox checked={false} disabled label={c.title}><span>{c.title} <Chip>later</Chip></span></Checkbox>
  {/each}
  <p class="muted">Choosing single capabilities comes in a later version.</p>
{/if}
