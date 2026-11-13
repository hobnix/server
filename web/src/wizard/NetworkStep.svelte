<script>
  // The Network step of the first-run wizard (issue #179): the result of the network check, the cards, "Check again" and the advice to reserve the
  // address on the router. DHCP only: no address form. The card is only chosen when the person wants another one; `nic` is bound to the choice.
  // The logic is netcheck.js.
  import Button from '../ui/Button.svelte';
  import Chip from '../ui/Chip.svelte';
  import Field from '../ui/Field.svelte';
  import Select from '../ui/Select.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import { tr } from '../i18n.js';
  import { get } from '../api.js';
  import { CHECK_PATH, NICS_PATH, ADVICE, viewRows, firstFailure, adviceFor, cards, nicOptions, defaultNic } from './netcheck.js';

  // nic: the chosen card (bindable); ok: the check passed (bindable, the wizard enables Next with it)
  let { nic = $bindable(''), ok = $bindable(false) } = $props();
  // one read on opening and one per "Check again": the check is a question the person asks, not a value to watch
  let checkRows = $state([]);
  let nicRows = $state([]);
  let loaded = $state(false);
  const view = $derived(viewRows(checkRows));
  const bad = $derived(firstFailure(checkRows));
  const address = $derived(adviceFor(checkRows));
  const list = $derived(cards(nicRows));
  let change = $state(false);

  $effect(() => { ok = view.length > 0 && !bad; });
  $effect(() => { if (!nic && nicRows.length) nic = defaultNic(nicRows); });
  const load = async () => {
    const [c, n] = await Promise.all([get(CHECK_PATH, true).catch(() => null), get(NICS_PATH, true).catch(() => null)]);
    checkRows = c?.rows ?? [];
    nicRows = n?.rows ?? [];
    loaded = true;
  };
  const again = () => { loaded = false; load(); };
  $effect(() => { load(); });
</script>

<div style="display:grid;gap:10px">
  {#if !loaded}
    <div style="color:var(--fg-3)">{tr('Checking the network…')}</div>
  {:else}
    {#each view as r (r.item)}
      <div style="display:flex;flex-wrap:wrap;align-items:center;gap:4px 14px">
        <StatusDot state={r.tone} label={r.label} />
        <span style="font-family:var(--mono);color:var(--fg-2)">{r.value}</span>
        {#if r.fix && r.tone !== 'ok'}<span style="color:var(--fg-3)">{tr(r.fix)}</span>{/if}
      </div>
    {/each}
    {#if bad}
      <div style="color:var(--fg-3)">{tr('Fix this first:')} {tr(bad.fix)}</div>
    {:else if view.length}
      <div style="color:var(--fg-3)">{tr(ADVICE)}{#if address} <Chip>{address}</Chip>{/if}</div>
    {/if}
  {/if}

  <div style="display:flex;flex-wrap:wrap;gap:10px;color:var(--fg-3)">
    {#each list as c (c.name)}
      <span><Chip tone={c.up ? '' : 'warn'}>{c.name}</Chip> {c.up ? tr('cable connected') : tr('no cable')}</span>
    {/each}
  </div>

  <div style="display:flex;gap:8px">
    <Button icon="arrows-clockwise" onclick={again}>{tr('Check again')}</Button>
    {#if list.length > 1}<Button variant="ghost" onclick={() => (change = !change)}>{tr('Use another card')}</Button>{/if}
  </div>
  {#if change && list.length > 1}
    <Field label={tr('Network card')} help={tr('The card this server uses. It gets its address by DHCP.')}>
      <Select bind:value={nic} options={nicOptions(nicRows)} />
    </Field>
  {/if}
</div>
