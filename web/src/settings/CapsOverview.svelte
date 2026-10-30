<script>
  // /settings/capabilities: every optional part and extension of this server with its switch (the Parts and Extensions cards of the old Settings
  // page). A row with a settings page of its own links to it.
  import { tip } from '../ui/tooltip.svelte.js';
  import { go } from '../route.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import Chip from '../ui/Chip.svelte';
  import layout from './layout.gen.json';
  import Fields from './Fields.svelte';
  import { fieldsFor } from './layout.js';
  import { useConfig } from './config.svelte.js';
  import { useParts, flip } from './parts.svelte.js';

  const { partList, parts: getParts } = useParts();
  const parts = $derived(getParts());
  const extensions = $derived(parts.filter((p) => p.kind === 'extension'));
  const plainParts = $derived(parts.filter((p) => p.kind !== 'extension' && !p.name.startsWith('edge-')));
  const { opts: getOpts } = useConfig();
  const fields = $derived(fieldsFor(layout, 'capabilities', getOpts()));
  const hasPage = (p) => !!layout.caps[p.name]?.entry;
</script>

<div class="page">
  <PageHeader title="Capabilities" crumb="Settings" sub="The optional parts of this server and the extensions, with their switches." />
  <div class="cols">
    <div class="card sec" id="parts">
      <div class="st">Parts</div>
      <p class="hp2">Optional parts of this server. Off means its pages and commands are not there. A part with a NixOS module changes at the next <code>hs rebuild</code>.</p>
      {#each plainParts as p (p.name)}
        <div class="prow">
          <StatusDot state={p.on ? 'ok' : 'off'} label={p.on ? 'on' : 'off'} bare />
          <div class="pt"><code>{p.name}</code><span class="hp">{p.title}</span></div>
          {#if p.nix}<Chip>rebuild</Chip>{/if}
          {#if hasPage(p)}<button use:tip={'Open the settings of this part'} class="btn sm" onclick={() => go(`/settings/capabilities/${p.name}`)}><i class="ph ph-sliders"></i>Settings</button>{/if}
          <button use:tip={!p.canSwitch ? 'This part cannot be switched here' : p.on ? 'Switch this part off (shows the plan)' : 'Switch this part on (shows the plan)'} class="btn sm" disabled={!p.canSwitch} onclick={() => flip(p)}>{p.on ? 'Switch off…' : 'Switch on…'}</button>
        </div>
      {:else}
        <div class="hp2">{partList.loaded ? (partList.error ? 'The parts could not be read.' : 'No optional parts.') : 'Loading…'}</div>
      {/each}
    </div>
    <div class="card sec" id="extensions">
      <div class="st">Extensions</div>
      <p class="hp2">Packages that add pages and commands (<code>hs ext</code>). Off by default; one without a NixOS module is on at once.</p>
      {#each extensions as p (p.name)}
        <div class="prow">
          <StatusDot state={p.on ? 'ok' : 'off'} label={p.on ? 'on' : 'off'} bare />
          <div class="pt"><code>{p.name}</code><span class="hp">{p.title}</span></div>
          {#if p.nix}<Chip>rebuild</Chip>{/if}
          <button use:tip={!p.canSwitch ? 'This part cannot be switched here' : p.on ? 'Switch this part off (shows the plan)' : 'Switch this part on (shows the plan)'} class="btn sm" disabled={!p.canSwitch} onclick={() => flip(p)}>{p.on ? 'Switch off…' : 'Switch on…'}</button>
        </div>
      {:else}
        <div class="hp2">{partList.loaded ? 'No extensions on this server.' : 'Loading…'}</div>
      {/each}
    </div>
  </div>
  {#if fields.length}<Fields opts={fields} />{/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .prow { display: flex; align-items: center; gap: 10px; }
  .pt { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .hp2 { margin: 0; font-size: 12.5px; color: var(--color-neutral-500); }
  .hp { font-size: 11.5px; color: var(--color-neutral-500); }
  .cols { column-width: 400px; column-gap: 14px; }
  .sec { padding: 14px 16px; gap: 10px; break-inside: avoid; margin-bottom: 14px; }
  .st { font-size: 14px; font-weight: 500; }
</style>
