<script>
  import PageHeader from '../shell/PageHeader.svelte';
  // The Data page: every read the collector keeps for the web interface (scripts/lib/collected-reads.tsv): how often, how old the kept output is,
  // how long the script takes. A read that is late (older than three times its interval) or never kept means the collector is stuck or the script
  // fails; a slow one is the page that makes you wait. Read only for now: the list is a file in the repo.
  import { poll, rows } from '../data.svelte.js';
  import Table from '../shell/Table.svelte';

  const st = poll('/api/sys/reads/status', 5000);

  // reads status: read, interval s, age s (-1 = never kept), ms, exit code, bytes (- = nothing kept yet)
  const num = (v) => (v === '-' || v === undefined || v === '' ? null : Number(v));
  const reads = $derived(rows(st).map((r) => {
    const every = num(r[1]), age = num(r[2]), ms = num(r[3]), rc = num(r[4]), bytes = num(r[5]);
    const state = age === null || age < 0 ? 'never' : age > Math.max(3 * every, 30) ? 'late' : rc ? 'failing' : 'fresh';
    return { read: r[0], every, age: age !== null && age >= 0 ? age : null, ms, rc, bytes, state };
  }));
  const late = $derived(reads.filter((r) => r.state === 'late' || r.state === 'never').length);
  const slow = $derived(reads.filter((r) => r.ms !== null && r.ms >= 5000).length);

  const secs = (s) => (s === null ? '' : s < 90 ? `${Math.round(s)} s` : s < 5400 ? `${Math.round(s / 60)} min` : `${Math.round(s / 3600)} h`);
  const took = (ms) => (ms === null ? '' : ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(1)} s`);
  const kb = (b) => (b === null ? '' : b < 1024 ? `${b} B` : `${(b / 1024).toFixed(1)} KB`);
  const tone = (s) => (s === 'fresh' ? 'var(--st-ok, var(--color-neutral-300))' : s === 'failing' ? 'var(--st-warn)' : 'var(--st-bad)');

  const columns = [
    { key: 'read', label: 'Read', value: (r) => r.read },
    { key: 'state', label: 'State', value: (r) => r.state },
    { key: 'every', sort: 'num', optional: true, label: 'Every', value: (r) => r.every, align: 'right' },
    { key: 'age', sort: 'num', label: 'Kept', value: (r) => r.age, align: 'right' },
    { key: 'ms', sort: 'num', label: 'Takes', value: (r) => r.ms, align: 'right' },
    { key: 'bytes', sort: 'num', optional: true, label: 'Size', value: (r) => r.bytes, align: 'right' },
  ];
</script>

<div class="page">
  <PageHeader title="Diagnostics" crumb="Monitoring" sub="How fresh the pages are, and what makes them slow." />

  <div class="note"><i class="ph ph-info"></i>
    <span>A timer reads these every few seconds and keeps the output in the state database, so a page opens without waiting for the scripts.
      {#if reads.length}{late ? `${late} read(s) are late or were never kept: is hs-reads-collect running? ` : 'All of them are on time. '}{slow ? `${slow} take 5 s or more. ` : ''}{/if}
      The refresh button in the top bar runs a page's scripts at once.</span>
  </div>

  <div class="card elev-sm" style="padding:12px 14px">
    <Table id="data-reads" {columns} rows={reads} key="read" compact loading={!st.loaded}
           empty={st.error ? 'The list could not be read.' : 'No read is collected (the list scripts/lib/collected-reads.tsv is empty or not there).'}>
      {#snippet cell(r, col)}
        {#if col.key === 'read'}<code>{r.read}</code>
        {:else if col.key === 'state'}<span style="color:{tone(r.state)}">{r.state}{r.state === 'failing' ? ` (exit ${r.rc})` : ''}</span>
        {:else if col.key === 'every'}<span class="c">{secs(r.every)}</span>
        {:else if col.key === 'age'}<span class="c">{secs(r.age)}</span>
        {:else if col.key === 'ms'}<span class="c" style="color:{r.ms >= 5000 ? 'var(--st-warn)' : ''}">{took(r.ms)}</span>
        {:else}<span class="c">{kb(r.bytes)}</span>{/if}
      {/snippet}
    </Table>
  </div>
  <div class="muted">The list of reads is <code>scripts/lib/collected-reads.tsv</code> in the repository (the words of the read, and how often in seconds). <code>hs sys state reads</code> and <code>hs sys reads status</code> show the same on the command line.</div>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .crumb { font-size: 11px; color: var(--color-neutral-500); }
  .tl { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
  .ttl { font-size: 20px; font-weight: 500; }
  .sub, .muted { font-size: 12px; color: var(--color-neutral-500); }
  .c { padding: 6px 8px; color: var(--color-neutral-300); font-variant-numeric: tabular-nums; }
  .note { display: flex; gap: 10px; align-items: center; padding: 10px 12px; border-radius: var(--r); background: var(--color-neutral-900); box-shadow: inset 0 0 0 1px var(--color-neutral-800); font-size: 12.5px; color: var(--color-neutral-300); }
</style>
