<script>
  // Step "Network and storage": fixed address, network (VLAN profile) and storage bindings; the same for every kind (a VM takes fast volumes only).
  import Button from '../../../ui/Button.svelte';
  import { poll, rows } from '../../../data.svelte.js';

  let { address = $bindable(''), profile = $bindable(''), binds = $bindable([]), type = 'container' } = $props();
  let nextId = 1;
  const pf = poll('/api/sys/ct/profiles', 60000);
  // name, network, description
  const profiles = $derived(rows(pf).map((r) => ({ name: r[0], net: r[1], desc: r[2] })));
  const sh = poll('/api/sys/shares/overview', 60000, 'shares-overview');
  const shareNames = $derived(rows(sh).filter((r) => r[1] !== 'other').map((r) => r[0]));
  const bindKinds = [['shares', 'Share'], ['sensitive', 'Sensitive share'], ['fast', 'Fast volume']];
  const addBind = () => { binds = [...binds, { id: nextId++, kind: 'shares', name: '', path: '', ro: false }]; };
  const dropBind = (id) => { binds = binds.filter((b) => b.id !== id); };
  const bindOk = (b) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$/.test(b.name.trim()) && /^\/(?!.*\.\.)[A-Za-z0-9._/-]{0,200}$/.test(b.path.trim());
  const bindsOk = $derived(binds.every(bindOk) && new Set(binds.map((b) => b.name.trim())).size === binds.length);
  const vmBulk = $derived(type === 'vm' && binds.some((b) => b.kind !== 'fast'));
</script>

<div class="field">
  <label for="ci-addr">Fixed address (optional)</label>
  <input id="ci-addr" class="input" bind:value={address} placeholder="10.10.95.25" autocomplete="off" spellcheck="false" />
</div>
<div class="field">
  <label for="ci-prof">Network</label>
  <select id="ci-prof" class="input" bind:value={profile}>
    <option value="">Default network</option>
    {#each profiles as p}<option value={p.name}>{p.name} ({p.net}{p.desc && p.desc !== '-' ? ', ' + p.desc : ''})</option>{/each}
  </select>
  {#if pf.loaded && pf.error}<div class="hint">The networks could not be read; the default one is used.</div>{/if}
</div>
<div class="field">
  <span class="lbl">Storage bindings <span class="opt">(optional)</span></span>
  {#each binds as b (b.id)}
    <div class="brow">
      <select class="input" aria-label="Kind" bind:value={b.kind}>{#each bindKinds as [v, l]}<option value={v}>{l}</option>{/each}</select>
      <input class="input" aria-label="Name" list="ci-shares" bind:value={b.name} placeholder={b.kind === 'fast' ? 'volume' : 'share'} autocomplete="off" spellcheck="false" />
      <input class="input" aria-label="Path inside" bind:value={b.path} placeholder="/media" autocomplete="off" spellcheck="false" />
      <label class="chk"><input type="checkbox" bind:checked={b.ro} />ro</label>
      <Button variant="ghost" class="btn-icon" tooltip={'Remove this binding'} type="button" aria-label="Remove this binding" onclick={() => dropBind(b.id)}><i class="ph ph-x"></i></Button>
    </div>
  {/each}
  <datalist id="ci-shares">{#each shareNames as n}<option value={n}></option>{/each}</datalist>
  <div><Button variant="ghost" size="sm" class="createinstance-sm" type="button" onclick={addBind}><i class="ph ph-plus"></i>Bind storage</Button></div>
  {#if binds.length && !bindsOk}<div class="hint bad">Each binding needs a different name and an absolute path without "..".</div>{/if}
  {#if vmBulk}<div class="hint bad">Share folders cannot go into a virtual machine; use a fast volume, or mount the Samba share inside it.</div>{/if}
</div>
<div class="hint">A share that does not exist yet is created when it is bound. The same storage can be bound later from the instance page.</div>

<style>
  .hint { font-size: 12px; color: var(--fg-3); }
  .hint.bad { color: var(--bad); }
  .lbl { display: block; font-size: 12px; margin-bottom: 5px; color: var(--fg-2); }
  .opt { color: var(--fg-3); }
  .brow { display: grid; grid-template-columns: 120px minmax(0, 1fr) minmax(0, 1fr) auto auto; gap: 6px; align-items: center; margin-bottom: 6px; }
  .chk { display: flex; align-items: center; gap: 4px; font-size: 12.5px; accent-color: var(--accent); }
  :global(.btn.createinstance-sm) { font-size: 12px; }
</style>
