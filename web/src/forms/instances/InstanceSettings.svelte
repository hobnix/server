<script>
  // Settings of one instance: `ct <name> set [--ram .. --cpu .. --disk .. --autostart yes|no --docker yes|no]` or `ct <name> ip --address <ip>`.
  // Only what differs from today's value is sent.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { ct, ondone = () => {} } = $props();
  const num = (v) => { const m = /^(\d+)/.exec(v ?? ''); return m ? m[1] : ''; };
  const yes = (v) => /^(yes|true|on)$/i.test((v ?? '').trim());

  const start = { ram: num(ct.ram), cpu: num(ct.cpu), disk: num(ct.disk), autostart: yes(ct.autostart), docker: yes(ct.docker), address: /^\d+\./.test(ct.address) ? ct.address : '' };
  let mode = $state('resources');
  let ram = $state(start.ram);
  let cpu = $state(start.cpu);
  let disk = $state(start.disk);
  let autostart = $state(start.autostart);
  let docker = $state(start.docker);
  let address = $state(start.address);

  const args = () => {
    if (mode === 'address') return address.trim() && address.trim() !== start.address ? [ct.name, 'ip', '--address', address.trim()] : null;
    const a = [ct.name, 'set'];
    if (ram.trim() && ram.trim() !== start.ram) a.push('--ram', ram.trim());
    if (cpu.trim() && cpu.trim() !== start.cpu) a.push('--cpu', cpu.trim());
    if (disk.trim() && disk.trim() !== start.disk) a.push('--disk', disk.trim());
    if (autostart !== start.autostart) a.push('--autostart', autostart ? 'yes' : 'no');
    if (docker !== start.docker) a.push('--docker', docker ? 'yes' : 'no');
    return a.length > 2 ? a : null;
  };
</script>

<CreateDialog kicker="Settings" title={`Settings of ${ct.name}`} area="ct" {args} {ondone}>
  {#snippet form()}
    <div class="seg" role="radiogroup" style="align-self:flex-start">
      <label class="seg-opt"><input type="radio" name="is-mode" value="resources" bind:group={mode} />Resources</label>
      <label class="seg-opt"><input type="radio" name="is-mode" value="address" bind:group={mode} />Fixed address</label>
    </div>
    {#if mode === 'resources'}
      <div class="row">
        <div class="field"><label for="is-ram">RAM limit (MiB, "none" removes it)</label><input id="is-ram" class="input" bind:value={ram} autocomplete="off" /></div>
        <div class="field"><label for="is-cpu">CPU limit</label><input id="is-cpu" class="input" bind:value={cpu} autocomplete="off" /></div>
      </div>
      <div class="field">
        <label for="is-disk">Disk size (GiB, can only grow)</label>
        <input id="is-disk" class="input" bind:value={disk} autocomplete="off" />
      </div>
      <label class="chk"><input type="checkbox" bind:checked={autostart} />Start at boot</label>
      <label class="chk"><input type="checkbox" bind:checked={docker} />Docker support (restart the instance afterwards)</label>
    {:else}
      <div class="field">
        <label for="is-addr">Fixed address</label>
        <input id="is-addr" class="input" bind:value={address} placeholder="10.10.95.25" autocomplete="off" spellcheck="false" />
      </div>
      <div class="hint">The instance restarts when the address changes.</div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .row { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .chk { display: flex; align-items: center; gap: 8px; font-size: 14px; cursor: pointer; accent-color: var(--color-accent); }
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
