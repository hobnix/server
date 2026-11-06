<script>
  import Button from './Button.svelte';
  // Wizard: the frame of one question per screen. It knows no capability and no draft; the page puts the answer in `children`.
  //   index (0-based), total      "Step 1 of 3" and the bar (hidden while `advanced`)
  //   question, help              the heading and the grey line under it
  //   primary, canNext, onnext    the right-hand button (its text is translated by the page)
  //   onback                      the arrow on the top left (not on index 0, not while `advanced`)
  //   <Wizard index={0} total={3} question="Which page?" help="..." primary="Next" onnext={go} onback={back}>...</Wizard>
  //   (the plain-fields Advanced view is not part of the frame: the capability page shows it instead of its tabs)
  import { tr } from '../i18n.js';
  import { progress } from '../settings/steps.js';
  let { index = 0, total = 1, question = '', help = '', primary = 'Next', canNext = true, onnext = () => {}, onback = () => {}, children } = $props();
  const p = $derived(progress(index, total));
</script>

<div class="wiz">
  <div class="prog">
    <span class="pt">{p.text}</span>
    <div class="bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow={p.pct} aria-label={p.text}><div class="fill" style:width="{p.pct}%"></div></div>
  </div>
  {#if index > 0}
    <button type="button" class="back" aria-label={tr('Back')} onclick={onback}><i class="ph ph-arrow-left"></i></button>
  {/if}
  <div class="q">{question}</div>
  {#if help}<div class="help">{help}</div>{/if}
  <div class="main">{@render children?.()}</div>
  <div class="foot">
    <Button variant="primary" type="button" disabled={!canNext} onclick={onnext}>{primary}</Button>
  </div>
</div>

<style>
  .wiz { display: flex; flex-direction: column; gap: 12px; }
  .prog { display: flex; flex-direction: column; gap: 6px; }
  .pt { font-size: 12px; color: var(--fg-3); }
  .bar { height: 4px; background: var(--line); }
  .fill { height: 100%; background: var(--accent); }
  .back { align-self: flex-start; padding: 4px 6px; border: 0; background: none; color: var(--fg-2); cursor: pointer; font-size: 16px; }
  .back:hover { color: var(--fg); }
  .q { font-size: 20px; font-weight: 600; }
  .help { font-size: 12px; color: var(--fg-3); }
  .main { display: flex; flex-direction: column; gap: 8px; margin-top: 4px; }
  .foot { display: flex; justify-content: flex-end; align-items: center; margin-top: 8px; }
</style>
