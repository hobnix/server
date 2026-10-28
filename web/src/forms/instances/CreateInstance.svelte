<script>
  // New instance: `hs sys ct plan|start <name> create [--type container|docker|vm] [--ram MB] [--cpu N] [--disk GB] [--address ip] [--profile name] [--bind kind:name:/path[:ro] ...]`
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { ondone = () => {} } = $props();
  let name = $state('');
  let type = $state('container');
  let ram = $state('');
  let cpu = $state('');
  let disk = $state('');
  let address = $state('');
  let profile = $state('');
  // bindings: storage attached once the instance runs (id keeps the rows apart while one is removed)
  let binds = $state([]);
  let nextId = 1;

  const pf = poll('/api/sys/ct/profiles', 60000);
  // name, network, description
  const profiles = $derived(rows(pf).map((r) => ({ name: r[0], net: r[1], desc: r[2] })));
  const sh = poll('/api/sys/shares/overview', 60000);
  const shareNames = $derived(rows(sh).filter((r) => r[1] !== 'other').map((r) => r[0]));
  const bindKinds = [['shares', 'Share'], ['sensitive', 'Sensitive share'], ['fast', 'Fast volume']];
  const addBind = () => { binds = [...binds, { id: nextId++, kind: 'shares', name: '', path: '', ro: false }]; };
  const dropBind = (id) => { binds = binds.filter((b) => b.id !== id); };
  const bindOk = (b) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$/.test(b.name.trim()) && /^\/(?!.*\.\.)[A-Za-z0-9._/-]{0,200}$/.test(b.path.trim());
  const bindsOk = $derived(binds.every(bindOk) && new Set(binds.map((b) => b.name.trim())).size === binds.length);
  const vmBulk = $derived(type === 'vm' && binds.some((b) => b.kind !== 'fast'));

  const kinds = [['container', 'Empty container'], ['docker', 'Docker'], ['vm', 'Virtual machine']];
  const args = () => {
    if (!name.trim()) return null;
    const a = [name.trim(), 'create', '--type', type];
    if (ram.trim()) a.push('--ram', ram.trim());
    if (cpu.trim()) a.push('--cpu', cpu.trim());
    if (disk.trim()) a.push('--disk', disk.trim());
    if (address.trim()) a.push('--address', address.trim());
    if (profile) a.push('--profile', profile);
    if (!bindsOk || vmBulk) return null;
    for (const b of binds) a.push('--bind', `${b.kind}:${b.name.trim()}:${b.path.trim()}${b.ro ? ':ro' : ''}`);
    return a;
  };
</script>

<CreateDialog title="Create an instance" area="ct" {args} {ondone}>
  {#snippet form()}
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
    <div class="row">
      <div class="field"><label for="ci-ram">RAM limit (MiB)</label><input id="ci-ram" class="input" bind:value={ram} placeholder="default" inputmode="numeric" autocomplete="off" /></div>
      <div class="field"><label for="ci-cpu">CPU limit</label><input id="ci-cpu" class="input" bind:value={cpu} placeholder="default" inputmode="numeric" autocomplete="off" /></div>
      <div class="field"><label for="ci-disk">Disk (GiB)</label><input id="ci-disk" class="input" bind:value={disk} placeholder="default" inputmode="numeric" autocomplete="off" /></div>
    </div>
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
          <button type="button" class="btn btn-ghost btn-icon" aria-label="Remove this binding" onclick={() => dropBind(b.id)}><i class="ph ph-x"></i></button>
        </div>
      {/each}
      <datalist id="ci-shares">{#each shareNames as n}<option value={n}></option>{/each}</datalist>
      <div><button type="button" class="btn btn-ghost sm" onclick={addBind}><i class="ph ph-plus"></i>Bind storage</button></div>
      {#if binds.length && !bindsOk}<div class="hint bad">Each binding needs a different name and an absolute path without "..".</div>{/if}
      {#if vmBulk}<div class="hint bad">Share folders cannot go into a virtual machine; use a fast volume, or mount the Samba share inside it.</div>{/if}
    </div>
    <div class="hint">A share that does not exist yet is created when it is bound. The same storage can be bound later from the instance page.</div>
  {/snippet}
</CreateDialog>

<style>
  .row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
  .hint { font-size: 12px; color: var(--color-neutral-500); }
  .hint.bad { color: var(--st-bad); }
  .lbl { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .opt { color: var(--color-neutral-500); }
  .brow { display: grid; grid-template-columns: 120px minmax(0, 1fr) minmax(0, 1fr) auto auto; gap: 6px; align-items: center; margin-bottom: 6px; }
  .chk { display: flex; align-items: center; gap: 4px; font-size: 12.5px; accent-color: var(--color-accent); }
  .sm { font-size: 12px; }
</style>
