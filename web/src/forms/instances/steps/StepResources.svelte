<script>
  // Step "Resources": memory, CPU and disk size. Empty = the default of the kind (hs sys ct plan shows what that is).
  let { ram = $bindable(''), cpu = $bindable(''), disk = $bindable(''), type = 'container' } = $props();
  const num = (v) => v.trim() === '' || /^[0-9]{1,7}$/.test(v.trim());
</script>

<div class="row">
  <div class="field"><label for="ci-ram">RAM limit (MiB)</label><input id="ci-ram" class="input" bind:value={ram} placeholder={type === 'vm' ? '2048' : 'default'} inputmode="numeric" autocomplete="off" /></div>
  <div class="field"><label for="ci-cpu">CPU limit</label><input id="ci-cpu" class="input" bind:value={cpu} placeholder={type === 'vm' ? '2' : 'default'} inputmode="numeric" autocomplete="off" /></div>
  <div class="field"><label for="ci-disk">Disk (GiB)</label><input id="ci-disk" class="input" bind:value={disk} placeholder={type === 'vm' ? '20' : 'default'} inputmode="numeric" autocomplete="off" /></div>
</div>
{#if !num(ram) || !num(cpu) || !num(disk)}<div class="hint bad">Use whole numbers.</div>{/if}
<div class="hint">{type === 'vm' ? 'The memory and the disk of a virtual machine are reserved for it.' : 'The memory limit is a ceiling, not reserved memory.'}</div>

<style>
  .row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
  .hint { font-size: 12px; color: var(--fg-3); }
  .hint.bad { color: var(--bad); }
</style>
