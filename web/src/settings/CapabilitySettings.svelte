<script>
  // /settings/capabilities/<name>: the settings page of one capability, the same for all (no per-capability component). From top to bottom:
  // the header (title, status tag, Advanced, the switch) and tabs: Status ([settings] status: StatusPanel) and Setup ([[settings.steps]]: WizardSteps); a part without
  // a wizard has its fields (layout.gen.json, page cap:<name>) as the tab Settings. Advanced replaces the tabs with the wizard's keys and the fields as plain key/value.
  // A capability that is off still has its page: it is how it gets switched on.
  import { route } from '../route.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import PageTabs from '../ui/PageTabs.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import Fields from './Fields.svelte';
  import StatusPanel from './StatusPanel.svelte';
  import WizardSteps from './WizardSteps.svelte';
  import layout from './layout.gen.json';
  import { fieldsFor } from './layout.js';
  import { useConfig } from './config.svelte.js';
  import { useParts, flip } from './parts.svelte.js';
  import { jobRunning } from '../ui.svelte.js';
  import { poll, rows } from '../data.svelte.js';
  import { setupDone } from './steps.js';
  import { partTag } from './tag.js';
  import Button from '../ui/Button.svelte';

  // the router gives no props: the name is the last part of the address (a caller may pass it)
  let { name = '' } = $props();
  const cap = $derived(name || route.path.split('/')[3] || '');
  const meta = $derived(layout.caps[cap]);
  let setupOff = $state('');

  const { list, opts: getOpts } = useConfig();
  const { partList, parts: getParts } = useParts();
  const part = $derived(getParts().find((p) => p.name === cap));
  const fields = $derived(fieldsFor(layout, `cap:${cap}`, getOpts()));
  // "set up" is not "listed as on": the docker wizard counts the container (owned in `hs sys docker status`), the others the part (steps.js setupDone)
  const dockerSt = poll(() => (meta?.apply === 'docker setup' ? '/api/sys/docker/status' : ''), 15000);
  const setUp = $derived(setupDone(meta?.apply, part?.on, rows(dockerSt)));

  // tabs: Status, Setup (the wizard); a part without a wizard keeps its fields as the tab Settings. Advanced replaces the tabs (wizard keys + fields).
  let tab = $state('');
  let advanced = $state(false);
  let running = $state('');
  const hasSteps = $derived(!!(meta?.steps?.length && meta?.apply));
  const tabs = $derived([
    ...(meta?.status ? [{ id: 'status', label: 'Status' }] : []),
    ...(hasSteps ? [{ id: 'setup', label: 'Setup' }] : []),
    ...(!hasSteps && fields.length ? [{ id: 'settings', label: 'Settings' }] : []),
  ]);
  // a part that is not set up yet opens on the wizard, else on the status
  const cur = $derived(tab && tabs.some((t) => t.id === tab) ? tab : hasSteps && !setUp ? 'setup' : tabs[0]?.id ?? '');
  // the tag of the header: where the part stands. A part with a NixOS module that is on but not running yet waits for `hs rebuild`.
  const tag = $derived(partTag(part, running));
</script>

<div class="page">
  <PageHeader title={meta?.title ?? cap} crumb="Settings · Capabilities">
    {#snippet actions()}
      {#if part}
        <StatusDot state={tag.state} label={tag.label} />
        {#if hasSteps}<Button tooltip={advanced ? 'Back to the status and the setup' : 'Every key of this part as plain fields'} onclick={() => (advanced = !advanced)}>{advanced ? 'Back' : 'Advanced'}</Button>{/if}
        <Button busy={jobRunning('parts', [part.on ? 'disable' : 'enable', part.name])} busyLabel="Switching…" disabled={!part.canSwitch} tooltip={!part.canSwitch ? 'This part cannot be switched here' : part.on ? 'Switch this part off (shows the plan)' : 'Switch this part on (shows the plan)'} onclick={() => flip(part)}>{part.on ? 'Switch off…' : 'Switch on…'}</Button>
      {:else if !partList.loaded}
        <span class="muted">Loading…</span>
      {/if}
    {/snippet}
  </PageHeader>

  {#if !meta}
    <div class="card"><EmptyState icon="puzzle-piece" title="Unknown part" text="This server has no part with this name." /></div>
  {:else}
    {#if !advanced && tabs.length > 1}<PageTabs {tabs} tab={cur} onpick={(id) => (tab = id)} />{/if}
    <!-- every panel stays mounted (hidden): the wizard keeps its draft and the status keeps polling while another tab is open -->
    {#if meta.status}<div hidden={advanced || cur !== 'status'}><StatusPanel read={meta.status} bind:off={setupOff} bind:running={running} /></div>{/if}
    {#if hasSteps}
      <div hidden={!advanced && cur !== 'setup'}><WizardSteps steps={meta.steps} apply={meta.apply} opts={getOpts()} off={setupOff} on={setUp} first={meta.apply === 'docker setup' && !setUp} {advanced} /></div>
    {/if}
    {#if fields.length && (advanced || !hasSteps)}
      <div hidden={!advanced && cur !== 'settings'}><Fields opts={fields} /></div>
    {:else if !hasSteps && !meta.status}
      <div class="card"><EmptyState icon="sliders" title="This part has no settings of its own." text="Switching it on or off is all there is to do." /></div>
    {/if}
    {#if list.loaded && list.error}<div class="muted">The settings could not be read.</div>{/if}
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .muted { font-size: 12px; color: var(--fg-3); }
</style>
