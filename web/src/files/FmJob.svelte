<script>
  // The job of the file manager on the page: while it runs a blue banner with files, bytes, speed, time left and Cancel; when it ended a green, amber or red
  // one that opens the result (moved, skipped, failed). The same job also has a row under Tasks in the bottom panel (ui.svelte.js track).
  import { tip } from '../ui/tooltip.svelte.js';
  import Banner from '../ui/Banner.svelte';
  import * as S from './selection.js';

  let { fm } = $props();
  const j = $derived(fm.job);
  const p = $derived(j?.p);
  const pct = $derived(p && p.bytesTotal > 0 ? Math.min(100, Math.round((p.bytesDone / p.bytesTotal) * 100)) : p && p.filesTotal > 0 ? Math.min(100, Math.round((p.filesDone / p.filesTotal) * 100)) : 0);
  const VERB = { copy: 'Copying', move: 'Moving', delete: 'Deleting', rename: 'Renaming', mkdir: 'Creating a folder' };
  const DONE = { copy: 'Copied', move: 'Moved', delete: 'Deleted', rename: 'Renamed', mkdir: 'Created' };
  const tone = $derived(!j ? 'info' : j.state === 'running' ? 'info' : j.state === 'done' ? (p?.skipped.n || p?.failed.n ? 'warn' : 'ok') : j.state === 'cancelled' ? 'warn' : j.state === 'gone' ? 'info' : 'bad');
</script>

{#if j}
  <Banner {tone} icon={j.state === 'running' ? 'arrows-clockwise' : undefined}>
    <div class="jb">
      {#if j.state === 'running'}
        <b>{VERB[j.op] ?? 'Working'}</b> {j.title}
        <div class="stat">
          {#if p}
            <span>{S.plural(p.filesDone || 0, 'file')}{Number.isFinite(p.filesTotal) ? ` of ${p.filesTotal}` : ''}</span>
            {#if Number.isFinite(p.bytesDone)}<span>{S.bytesTxt(p.bytesDone)}{Number.isFinite(p.bytesTotal) ? ` of ${S.bytesTxt(p.bytesTotal)}` : ''}</span>{/if}
            {#if Number.isFinite(p.speed) && p.speed > 0}<span>{S.bytesTxt(p.speed)}/s</span>{/if}
            {#if S.etaTxt(p.eta)}<span>{S.etaTxt(p.eta)} left</span>{/if}
            {#if p.phase}<span class="ph">{p.phase}</span>{/if}
          {:else}<span>Starting…</span>{/if}
        </div>
        <div class="ub"><div class="track" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow={pct} aria-label="Progress"><div class="fill" style="width:{pct}%"></div></div><span class="pc">{pct} %</span></div>
        {#if p?.current}<div class="cur mono">{p.current}</div>{/if}
      {:else if j.state === 'gone'}
        <b>{j.title}</b> The server no longer knows this job. It has ended or the server was restarted; the lists show what is there now.
      {:else}
        <b>{j.state === 'done' ? `${DONE[j.op] ?? 'Done'}.` : j.state === 'cancelled' ? 'Cancelled.' : 'Failed.'}</b> {j.title}
        {#if p}
          <span class="stat"><span>{S.plural(p.filesDone || 0, 'file')} done</span>{#if p.skipped.n}<span>{p.skipped.n} skipped</span>{/if}{#if p.failed.n}<span>{p.failed.n} failed</span>{/if}</span>
          {#if j.state === 'cancelled'}<div class="cur">What was copied stays; nothing unverified was removed.</div>{/if}
        {/if}
      {/if}
    </div>
    {#snippet action()}
      {#if j.state === 'running'}
        <button class="btn sm" disabled={j.cancelling} use:tip={'Stops cleanly: what is copied stays, nothing unverified is removed'} onclick={() => fm.cancelJob()}>{j.cancelling ? 'Cancelling…' : 'Cancel'}</button>
      {:else}
        {#if p && (p.skipped.n || p.failed.n || j.state !== 'done')}<button class="btn sm" onclick={() => (fm.result = true)}>Details</button>{/if}
        <button class="btn sm btn-ghost" aria-label="Dismiss" use:tip={'Dismiss'} onclick={() => fm.dismissJob()}><i class="ph ph-x"></i></button>
      {/if}
    {/snippet}
  </Banner>
{/if}

<style>
  .jb { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .stat { display: flex; gap: 14px; flex-wrap: wrap; font: 12.5px var(--mono); color: var(--fg-2); }
  .ph { color: var(--info-ink); }
  .ub { display: flex; align-items: center; gap: 10px; max-width: 520px; margin-top: 4px; }
  .track { flex: 1; position: relative; height: 10px; background: var(--panel-3); overflow: hidden; -webkit-mask-image: repeating-linear-gradient(90deg, #000 0 4px, transparent 4px 6px); mask-image: repeating-linear-gradient(90deg, #000 0 4px, transparent 4px 6px); }
  .fill { position: absolute; left: 0; top: 0; bottom: 0; background: var(--info); transition: width 0.4s; }
  .pc { font: 12px var(--mono); color: var(--fg-2); min-width: 3em; }
  .cur { font-size: 12px; color: var(--fg-3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>
