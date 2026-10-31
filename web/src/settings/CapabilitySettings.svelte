<script>
  // /settings/capabilities/<name>: the settings page of one capability, the same for all (no per-capability component). From top to bottom:
  // the header (title, on/off, the switch), a status block ([settings] status: StatusPanel) and a setup block ([[settings.steps]]: Steps), then the fields of the
  // keys that belong to this capability (layout.gen.json, page cap:<name>). A capability that is off still has its page: it is how it gets switched on.
  import { tip } from '../ui/tooltip.svelte.js';
  import { route } from '../route.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import Chip from '../ui/Chip.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import Fields from './Fields.svelte';
  import StatusPanel from './StatusPanel.svelte';
  import Steps from './Steps.svelte';
  import layout from './layout.gen.json';
  import { fieldsFor } from './layout.js';
  import { useConfig } from './config.svelte.js';
  import { useParts, flip } from './parts.svelte.js';

  // the router gives no props: the name is the last part of the address (a caller may pass it)
  let { name = '' } = $props();
  const cap = $derived(name || route.path.split('/')[3] || '');
  const meta = $derived(layout.caps[cap]);
  let setupOff = $state('');

  const { list, opts: getOpts } = useConfig();
  const { partList, parts: getParts } = useParts();
  const part = $derived(getParts().find((p) => p.name === cap));
  const fields = $derived(fieldsFor(layout, `cap:${cap}`, getOpts()));
</script>

<div class="page">
  <PageHeader title={meta?.title ?? cap} crumb="Settings · Capabilities">
    {#snippet actions()}
      {#if part}
        <StatusDot state={part.on ? 'ok' : 'off'} label={part.on ? 'on' : 'off'} />
        {#if part.nix}<Chip>rebuild</Chip>{/if}
        <button use:tip={!part.canSwitch ? 'This part cannot be switched here' : part.on ? 'Switch this part off (shows the plan)' : 'Switch this part on (shows the plan)'} class="btn" disabled={!part.canSwitch} onclick={() => flip(part)}>{part.on ? 'Switch off…' : 'Switch on…'}</button>
      {:else if !partList.loaded}
        <span class="muted">Loading…</span>
      {/if}
    {/snippet}
  </PageHeader>

  {#if !meta}
    <div class="card"><EmptyState icon="puzzle-piece" title="Unknown part" text="This server has no part with this name." /></div>
  {:else}
    {#if meta.status}<StatusPanel read={meta.status} bind:off={setupOff} />{/if}
    {#if meta.steps?.length && meta.apply}<Steps steps={meta.steps} apply={meta.apply} opts={getOpts()} off={setupOff} />{/if}
    {#if fields.length}
      <Fields opts={fields} />
    {:else}
      <div class="card"><EmptyState icon="sliders" title="This part has no settings of its own." text="Switching it on or off is all there is to do." /></div>
    {/if}
    {#if list.loaded && list.error}<div class="muted">The settings could not be read.</div>{/if}
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .muted { font-size: 12px; color: var(--fg-3); }
</style>
