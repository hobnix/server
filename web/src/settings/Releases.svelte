<script>
  // Settings, Releases: the update channel (stable, beta, edge) side by side, the current one marked, what the next update would install.
  // Choosing a channel opens the plan (`hs sys release plan channel <name>`): it checks the tag signature, says what happens and, for a newer
  // channel, asks for the channel name. Nothing is installed here; the Update button is on the Updates page.
  import { poll, rows } from '../data.svelte.js';
  import { openPlan, jobRunning } from '../ui.svelte.js';
  import { prefetchPlan } from '../api.js';
  import { tr } from '../i18n.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import Button from '../ui/Button.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import { CHANNELS, WHO, releaseModel, nextUpdate, planArgs } from './releases.js';

  let { deck } = $props();

  const show = poll(() => (deck?.data?.locked ? '' : '/api/sys/release/show'), 10000);
  const m = $derived(releaseModel(rows(show)));
  const next = $derived(nextUpdate(m));
  const nextText = $derived(next ? tr(next.text).replace('{ref}', m.ref) : '');
  const labels = { stable: 'Stable', beta: 'Beta', edge: 'Edge' };
</script>

<div class="page">
  <PageHeader title="Releases" crumb="Settings" sub="Which version this server follows when it updates." />

  {#if !m}
    <div class="muted">{show.loaded ? (show.error ? tr('The release channel could not be read.') : '') : tr('Loading…')}</div>
  {:else}
    <div class="card sec">
      <div class="st">{tr('This server')}</div>
      <div class="kv"><span>{tr('Installed version')}</span><code>{m.installed}</code></div>
      <div class="kv"><span>{tr('Next update')}</span><code>{m.ref}</code></div>
      <div class="kv"><span>{tr('Signature')}</span><span>{m.signed === 'yes' ? tr('valid') : m.signed === 'no' ? tr('not valid') : '-'}</span></div>
      <StatusDot state={next.state} label={nextText} />
    </div>

    <div class="chs">
      {#each CHANNELS as c}
        <div class="card sec ch" class:cur={c === m.channel}>
          <div class="st">{tr(labels[c])}{#if c === m.channel} <span class="mark">{tr('current')}</span>{/if}</div>
          <p class="hp2">{tr(WHO[c])}</p>
          <div class="kv"><span>{tr('Would install')}</span><code>{m.offers[c]?.ref ?? '-'}</code></div>
          {#if c !== m.channel}
            <Button class="b13" busy={jobRunning('release', planArgs(c))} tooltip={tr('Shows the plan first; nothing is installed')}
              onpointerenter={() => prefetchPlan('release', planArgs(c))} onfocus={() => prefetchPlan('release', planArgs(c))}
              onclick={() => openPlan('release', planArgs(c), `${tr('Switch to')} ${tr(labels[c])}`)}>{tr('Switch to')} {tr(labels[c])}…</Button>
          {/if}
        </div>
      {/each}
    </div>
    <p class="hp2">{tr('Moving to an older channel keeps the installed version: the server does not go back, it waits until the channel catches up.')}</p>
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .b13 { font-size: 13px; }
  .hp2 { margin: 0; font-size: 12.5px; color: var(--color-neutral-500); }
  .chs { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; }
  .sec { padding: 14px 16px; gap: 10px; }
  .ch.cur { box-shadow: inset 0 0 0 1px var(--accent); }
  .mark { font-size: 11px; font-weight: 400; color: var(--accent); margin-left: 6px; }
  .st { font-size: 14px; font-weight: 500; }
  .kv { display: flex; justify-content: space-between; gap: 12px; font-size: 13px; }
  .kv span:first-child { color: var(--color-neutral-500); }
  .muted { font-size: 12px; color: var(--fg-3); }
</style>
