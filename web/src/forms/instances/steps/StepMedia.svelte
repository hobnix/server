<script>
  // Step "Install image" (virtual machines only): one image of the ISO library (`hs sys iso list`), or none (the VM then boots the Debian image).
  import ChoiceList from '../../../ui/ChoiceList.svelte';
  import { poll, rows } from '../../../data.svelte.js';
  import { bytes } from '../../../format.js';

  let { iso = $bindable('') } = $props();
  const lst = poll('/api/sys/iso/list', 30000, 'iso-list');
  // name, bytes, algo, checksum, checked (yes|no), source, added, used by
  const images = $derived(rows(lst).map((r) => ({ name: r[0], size: Number(r[1]), checked: r[4] === 'yes' })));
  const options = $derived([
    { id: '', label: 'No image', text: 'A ready Debian image is installed.', recommended: false },
    ...images.map((i) => ({ id: i.name, label: i.name, text: `${bytes(i.size)}, ${i.checked ? 'checksum verified' : 'added without a checksum'}` })),
  ]);
</script>

<ChoiceList {options} value={iso} onpick={(id) => (iso = id)} label="Install image" />
{#if lst.loaded && !images.length}<div class="hint">The ISO library is empty. Add an image under Instances > ISO images, then come back.</div>{/if}
<div class="hint">With an image the VM starts empty and boots from it; remove the image from the VM after the installation.</div>

<style>
  .hint { font-size: 12px; color: var(--fg-3); }
</style>
