<script>
  // The job records (ADR 0004) in the Jobs panel: newest first, finished, failed, cancelled and interrupted jobs stay after their unit is gone.
  // The list is read once and again when a job.* event arrives on /api/events (ADR 0005); only while that stream is down it polls (15 s).
  // A click on a row reads the whole record (`sys jobs record <id>`: source, initiator, error), which the list does not carry.
  import { onDestroy } from 'svelte';
  import { get } from '../api.js';
  import { live } from '../live.svelte.js';
  import { tr } from '../i18n.js';
  import { bytes } from '../format.js';
  import StatusDot from '../ui/StatusDot.svelte';
  import Table from './Table.svelte';
  import Button from '../ui/Button.svelte';
  import { openCreate } from '../ui.svelte.js';
  import RunQuestions from '../forms/ops/RunQuestions.svelte';
  import { parseRecord, stateDot, stateKnown, stepText, percent, progressText, clock, duration, lastJobEvent, latestOnly } from '../jobrecords.js';

  let { onload = () => {} } = $props();

  let list = $state(null);       // parsed records, newest first; null before the first answer
  let failed = $state(false);
  let open = $state(null);       // id of the row shown in the detail
  let detail = $state(null);     // the full record of `open`
  let detailErr = $state('');
  let now = $state(Date.now());

  // reads can overlap (a slow read from job.running must not overwrite the answer after job.ok): latestOnly drops the older answer
  const readList = latestOnly(() => get('/api/sys/jobs/records?n=100'), (d) => {
    list = (d.rows ?? []).map(parseRecord);
    failed = false;
    onload(list.length);
  });
  async function load() {
    try { await readList(); } catch { failed = true; }
  }
  async function loadDetail(id) {
    try { const d = await get(`/api/sys/jobs/record/${encodeURIComponent(id)}`); if (open === id) { detail = d; detailErr = ''; } }
    catch (e) { if (open === id) { detail = null; detailErr = e.message || 'The record could not be read.'; } }
  }

  // read again when a job.* event arrives; the first read runs at once. The baseline is the newest job event that is already in the log at mount
  // (the first read has it); every later one reads again, also the first of a page that had none (it used to be taken for the baseline and lost,
  // so a job that started with job.queued and job.running together did not show until a reload).
  let lastJob = lastJobEvent(live.events)?.id ?? 0;
  $effect(() => {
    const ev = lastJobEvent(live.events);
    if (!ev || ev.id === lastJob) return;
    lastJob = ev.id;
    load();
    if (open) loadDetail(open);
  });
  // a step or progress update counts `jobs-records` up (no log row, scripts/job-record.py); the first value is the baseline
  let lastGen = live.gen['jobs-records'];
  $effect(() => {
    const g = live.gen['jobs-records'];
    if (g === lastGen) return;
    lastGen = g;
    load();
    if (open) loadDetail(open);
  });
  $effect(() => { if (list === null) load(); });
  // no stream: poll, because nothing says when a job changed
  $effect(() => {
    if (live.open) return;
    const t = setInterval(() => { load(); if (open) loadDetail(open); }, 15000);
    return () => clearInterval(t);
  });
  const tick = setInterval(() => { now = Date.now(); }, 1000);
  onDestroy(() => clearInterval(tick));

  function pick(r) {
    if (open === r.id) { open = null; detail = null; return; }
    open = r.id; detail = null; detailErr = '';
    loadDetail(r.id);
  }

  const columns = [
    { key: 'started', label: 'Started', value: (r) => r.started ?? r.queued ?? '' },
    { key: 'description', label: 'Job' },
    { key: 'state', label: 'State' },
    { key: 'step', label: 'Step', sort: false, optional: true },
    { key: 'progress', label: 'Progress', sort: false, optional: true },
    { key: 'duration', label: 'Took', sort: false, optional: true },
  ];
  const word = (s) => (stateKnown(s) ? tr(s) : s || '?');
  const bar = (r) => percent(r.progress);
  const kv = (d) => {
    const x = [];
    const add = (k, v) => { if (v !== null && v !== undefined && v !== '') x.push([k, v]); };
    add('Id', d.id); add('Source', d.source); add('Initiator', d.initiator); add('Unit', d.unit);
    add('Queued', clock(d.queued)); add('Started', clock(d.started)); add('Ended', clock(d.ended)); add('Exit', d.exit);
    return x;
  };
</script>

{#if failed && list === null}
  <div class="empty">{tr('The job records could not be read.')}</div>
{:else}
  <div class="tablescroll">
    <Table id="job-records" {columns} rows={list ?? []} key="id" onrow={pick} selected={open} loading={list === null} empty={tr('No job records yet.')} compact>
      {#snippet cell(r, col)}
        {#if col.key === 'started'}<span class="muted">{clock(r.started ?? r.queued)}</span>
        {:else if col.key === 'description'}{r.description}
        {:else if col.key === 'state'}<StatusDot state={stateDot(r.state)} label={(r.state === 'waiting' ? tr('waiting for input') : word(r.state)) + (r.state === 'failed' && r.exit !== null ? ` (exit ${r.exit})` : '')} />
        {:else if col.key === 'step'}<span class="muted">{stepText(r.step, r.state)}</span>
        {:else if col.key === 'progress'}
          {#if r.progress}
            {#if bar(r) !== null}<span class="pbar" role="progressbar" aria-valuenow={bar(r)} aria-valuemin="0" aria-valuemax="100"><span style="width:{bar(r)}%"></span></span>{/if}
            <span class="muted">{progressText(r.progress, bytes)}</span>
          {/if}
        {:else if col.key === 'duration'}<span class="muted">{duration(r.started, r.ended, now)}</span>
        {/if}
      {/snippet}
    </Table>
  </div>
  {#if open}
    <div class="detail">
      {#if detailErr}<div class="err">{detailErr}</div>
      {:else if !detail}<div class="muted">{tr('Loading…')}</div>
      {:else}
        <div class="kv">{#each kv(detail) as [k, v]}<span class="k">{tr(k)}</span><span class="mono">{v}</span>{/each}</div>
        {#if detail.state === 'waiting'}<div><Button variant="primary" size="sm" onclick={() => openCreate(RunQuestions, { job: detail.id })}>{tr('Answer the question')}</Button></div>{/if}
        {#if detail.step && stepText(detail.step, detail.state)}<div>{tr('Step')}: {stepText(detail.step, detail.state)}</div>{/if}
        {#if detail.error}<div class="err"><strong>{detail.error.category ?? ''}</strong> {detail.error.message ?? ''}</div>{/if}
        {#if detail.cancel}<div class="muted">{tr('Cancel requested')}{detail.cancel.requested_by ? ` · ${detail.cancel.requested_by}` : ''}</div>{/if}
      {/if}
    </div>
  {/if}
{/if}

<style>
  .detail { padding: 8px 12px; border-top: 1px solid var(--line); font-size: 12px; display: grid; gap: 6px; }
  .kv { display: grid; grid-template-columns: max-content 1fr; gap: 2px 14px; }
  .k { color: var(--fg-3); }
  .err { color: var(--bad); }
  .pbar { display: inline-block; width: 70px; height: 6px; background: var(--line); margin-right: 8px; vertical-align: middle; }
  .pbar > span { display: block; height: 100%; background: var(--accent); }
</style>
