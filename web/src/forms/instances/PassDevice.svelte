<script>
  // Pass a device to an instance: `ct <name> add-device --kind usb|gpu|pci --id <id> [--name <device name>]`
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import Chip from '../../ui/Chip.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { hwOf, canPass } from '../../pages/instances/devices.js';
  import { isVm } from '../../pages/instances/ct.js';

  let { ct, ondone = () => {} } = $props();
  const vm = $derived(isVm(ct));
  let kind = $state('usb');
  let picked = $state('');
  let typed = $state('');
  let dname = $state('');

  const hw = poll('/api/sys/ct/hardware', 30000);
  const all = $derived(rows(hw).map(hwOf));
  const kinds = $derived(vm ? [['usb', 'USB'], ['gpu', 'GPU'], ['pci', 'PCI']] : [['usb', 'USB'], ['gpu', 'GPU']]);
  const shown = $derived(all.filter((h) => h.kind === kind).map((h) => ({ ...h, can: canPass(h, vm) })));
  const typedOk = $derived(/^[0-9a-f]{4}:[0-9a-f]{4}$/.test(typed.trim()));
  const nameOk = $derived(!dname.trim() || /^[a-z][a-z0-9-]{0,40}$/.test(dname.trim()));

  const args = () => {
    const id = kind === 'usb' && typed.trim() ? (typedOk ? typed.trim() : '') : picked;
    if (!id || !nameOk) return null;
    const a = [ct.name, 'add-device', '--kind', kind, '--id', id];
    if (dname.trim()) a.push('--name', dname.trim());
    return a;
  };
</script>

<CreateDialog kicker="Devices" title={`Pass a device to ${ct.name}`} area="ct" {args} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="pd-kind">Kind</label>
      <div id="pd-kind" class="seg" role="radiogroup">
        {#each kinds as [v, l]}
          <label class="seg-opt"><input type="radio" name="pd-kind" value={v} bind:group={kind} onchange={() => { picked = ''; typed = ''; }} />{l}</label>
        {/each}
      </div>
    </div>
    <div class="rows">
      {#each shown as h (h.id)}
        <div class="r" class:off={!h.can.ok}>
          <label class="radio rt">
            <input type="radio" name="pd-dev" value={h.id} bind:group={picked} disabled={!h.can.ok} />
            <span class="dot"></span>
            <span>{h.product || h.vidpid || h.id}</span>
            <span class="kd">{h.vendor}</span>
            <span class="mono">{h.id}</span>
            {#if h.usedBy}<Chip>in {h.usedBy}</Chip>{/if}
          </label>
          {#if !h.can.ok}<div class="kd why">{h.can.why}</div>{/if}
        </div>
      {:else}
        <div class="kd pad">{hw.loaded ? 'No devices of this kind found.' : 'Loading…'}</div>
      {/each}
    </div>
    {#if kind === 'usb'}
      <div class="field">
        <label for="pd-typed">Not plugged in? vendor:product</label>
        <input id="pd-typed" class="input" bind:value={typed} placeholder="04f9:0042" autocomplete="off" spellcheck="false" />
        {#if typed.trim() && !typedOk}<span class="kd">Four hex digits, a colon, four hex digits.</span>{/if}
      </div>
    {/if}
    <div class="field">
      <label for="pd-name">Device name (optional)</label>
      <input id="pd-name" class="input" bind:value={dname} placeholder="printer" autocomplete="off" spellcheck="false" />
    </div>
  {/snippet}
</CreateDialog>

<style>
  .rows { border: 1px solid var(--line); max-height: 260px; overflow-y: auto; }
  .r { padding: 8px 10px; border-bottom: 1px solid var(--line); }
  .r:last-child { border-bottom: 0; }
  .rt { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; min-width: 0; }
  .r.off .rt { opacity: 0.55; cursor: not-allowed; }
  .why { margin-top: 2px; }
  .pad { padding: 10px; font-size: 12.5px; }
  .mono { font-size: 12px; }
</style>
