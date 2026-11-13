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
  import { poll, refresh, rows as rowsOf } from '../data.svelte.js';
  import { CHECK_PATH, NICS_PATH, ADVICE, viewRows, firstFailure, adviceFor, cards, nicOptions, defaultNic } from './netcheck.js';

  // nic: the chosen card (bindable); ok: the check passed (bindable, the wizard enables Next with it)
  let { nic = $bindable(''), ok = $bindable(false) } = $props();
  const check = poll(CHECK_PATH, 5000);
  const nics = poll(NICS_PATH, 15000);
  const checkRows = $derived(rowsOf(check));
  const nicRows = $derived(rowsOf(nics));
  const view = $derived(viewRows(checkRows));
  const bad = $derived(firstFailure(checkRows));
  const address = $derived(adviceFor(checkRows));
  const list = $derived(cards(nicRows));
  let change = $state(false);

  $effect(() => { ok = view.length > 0 && !bad; });
  $effect(() => { if (!nic && nicRows.length) nic = defaultNic(nicRows); });
  const again = () => refresh([CHECK_PATH, NICS_PATH]);
</script>

<div class="net">
  {#if !check.loaded}
    <div class="muted">{tr('Checking the network…')}</div>
  {:else}
    {#each view as r (r.item)}
      <div class="row">
        <StatusDot state={r.tone} label={r.label} />
        <span class="val">{r.value}</span>
        {#if r.fix && r.tone !== 'ok'}<span class="fix">{tr(r.fix)}</span>{/if}
      </div>
    {/each}
    {#if bad}
      <div class="muted">{tr('Fix this first:')} {tr(bad.fix)}</div>
    {:else if view.length}
      <div class="muted">{tr(ADVICE)}{#if address} <Chip>{address}</Chip>{/if}</div>
    {/if}
  {/if}

  <div class="cards">
    {#each list as c (c.name)}
      <span><Chip tone={c.up ? '' : 'warn'}>{c.name}</Chip> {c.up ? tr('cable connected') : tr('no cable')}</span>
    {/each}
  </div>

  <div class="acts">
    <Button icon="arrows-clockwise" onclick={again}>{tr('Check again')}</Button>
    {#if list.length > 1}<Button variant="ghost" onclick={() => (change = !change)}>{tr('Use another card')}</Button>{/if}
  </div>
  {#if change && list.length > 1}
    <Field label={tr('Network card')} help={tr('The card this server uses. It gets its address by DHCP.')}>
      <Select bind:value={nic} options={nicOptions(nicRows)} />
    </Field>
  {/if}
</div>

<style>
  .net { display: grid; gap: 10px; }
  .row { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 14px; }
  .val { font-family: var(--mono); color: var(--fg-2); }
  .fix { color: var(--fg-3); }
  .cards { display: flex; flex-wrap: wrap; gap: 10px; color: var(--fg-3); }
  .acts { display: flex; gap: 8px; }
</style>
