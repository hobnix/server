<script>
  // ChoiceList: one question, one answer. Radio rows only (no multiple choice); the whole row is the button.
  //   options  [{ id, label, text, recommended }]   value  the selected id or ''   onpick(id)   label  the aria-label of the group
  //   <ChoiceList options={step.options} value={picked} onpick={(id) => (picked = id)} label={step.question} />
  import Chip from './Chip.svelte';
  import { tr } from '../i18n.js';
  let { options = [], value = '', onpick = () => {}, label = '' } = $props();
</script>

<div class="list" role="radiogroup" aria-label={label}>
  {#each options as o (o.id)}
    <button type="button" class="row" class:on={value === o.id} role="radio" aria-checked={value === o.id} onclick={() => onpick(o.id)}>
      <span class="box" aria-hidden="true"></span>
      <span class="body">
        <span class="top"><span class="lbl">{o.label}</span>{#if o.recommended}<Chip>{tr('recommended')}</Chip>{/if}</span>
        <span class="txt">{o.text}</span>
      </span>
    </button>
  {/each}
</div>

<style>
  .list { display: flex; flex-direction: column; gap: 8px; }
  .row { display: flex; align-items: flex-start; gap: 12px; width: 100%; padding: 12px 14px; text-align: left; cursor: pointer; font: inherit; color: var(--fg);
         border: 1px solid var(--line); background: var(--panel); border-radius: 0; }
  .row:hover { background: var(--panel-2); }
  .row.on { border-color: var(--accent); background: color-mix(in oklch, var(--accent) 12%, transparent); }
  .box { flex: none; width: 14px; height: 14px; margin-top: 2px; border: 1px solid var(--line-2); }
  .on .box { background: var(--accent); border-color: var(--accent); }
  .body { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .top { display: flex; align-items: center; gap: 8px; }
  .lbl { font-size: 14px; font-weight: 500; }
  .txt { font-size: 12px; color: var(--fg-3); }
</style>
