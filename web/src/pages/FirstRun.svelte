<script>
  import { onMount } from 'svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import Wizard from '../ui/Wizard.svelte';
  import Button from '../ui/Button.svelte';
  import { tr } from '../i18n.js';
  import { ui } from '../ui.svelte.js';
  import { go } from '../route.svelte.js';
  import { session } from '../api.js';
  import { FIRST_RUN_STEPS, active, clampIndex } from '../setup/steps.js';
  import AccountStep from '../setup/AccountStep.svelte';
  import PresetStep from '../setup/PresetStep.svelte';
  import DoneStep from '../setup/DoneStep.svelte';

  // SLOTS: network (#179), storage (#181): one line each here when the step exists
  const BUILT = { account: AccountStep, preset: PresetStep, done: DoneStep };
  const steps = active(FIRST_RUN_STEPS, Object.keys(BUILT));
  let at = $state(0);
  let user = $state('');
  let save = $state(null);
  let waiting = $state(false);
  const step = $derived(steps[clampIndex(at, steps.length)]);
  const Body = $derived(BUILT[step.id]);
  const advance = () => { at = clampIndex(at + 1, steps.length); };

  onMount(async () => {
    if (!ui.features.setup_wizard) { go('/setup'); return; }
    try { user = (await session())?.user ?? ''; } catch { /* the name stays empty */ }
  });
  // a step's save() returns true to advance now, false when it opened a plan (the page then waits for it to close)
  function next() {
    if (!save || save()) { if (step.id !== 'done') advance(); return; }
    waiting = true;
  }
  // after a plan closed: Finish may have closed the wizard; any other step moves on
  $effect(() => {
    if (!waiting || ui.dialog) return;
    waiting = false;
    (async () => {
      try { const s = await session(); if (s) ui.features = s.features; } catch { /* keep the old answer */ }
      if (!ui.features.setup_wizard) go('/setup');
      else if (step.id !== 'done') advance();
    })();
  });
</script>

<div class="page">
  <PageHeader title="First setup" crumb={ui.host} />
  <Wizard index={clampIndex(at, steps.length)} total={steps.length} question={tr(step.question)} help={tr(step.help)} primary={tr(step.primary)} onnext={next} onback={() => { at = clampIndex(at - 1, steps.length); }}>
    {#key step.id}<Body {user} bind:save />{/key}
  </Wizard>
  {#if step.id !== 'done'}
    <div><Button variant="ghost" tooltip="Leave this step as it is" onclick={advance}>Skip</Button></div>
  {/if}
</div>
