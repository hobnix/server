<script>
  // Monitoring > Test-lab (capability testlab): start a run (a plan first, then a job on the Jobs page) and list the last runs (`hs sys testlab results`).
  import PageHeader from '../shell/PageHeader.svelte';
  import Table from '../shell/Table.svelte';
  import Button from '../ui/Button.svelte';
  import Banner from '../ui/Banner.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import { poll, rows } from '../data.svelte.js';
  import { ui, openPlan, jobRunning } from '../ui.svelte.js';
  import { tr } from '../i18n.js';

  const on = $derived(Array.isArray(ui.features.capabilities) && ui.features.capabilities.includes('testlab'));
  const st = poll(() => (on ? '/api/sys/testlab/results' : ''), 15000, undefined);
  // newest first: [run, stage, result, exit, ref, commit, started, ended]
  const list = $derived(rows(st).map(([run, stage, result, exit, ref, commit, started, ended]) => ({ run, stage, result, exit, ref, commit, started, ended })).reverse());
  const dot = (r) => ({ ok: 'ok', failed: 'bad', error: 'bad', skipped: 'warn' }[r] || 'off');
  const columns = [
    { key: 'run', label: 'Started', value: (r) => r.run },
    { key: 'stage', label: 'Stage', value: (r) => r.stage },
    { key: 'result', label: 'Result', value: (r) => r.result },
    { key: 'ref', label: 'Ref', value: (r) => r.ref },
    { key: 'commit', label: 'Commit', optional: true, value: (r) => r.commit },
    { key: 'ended', label: 'Ended', optional: true, value: (r) => r.ended },
  ];
</script>

<div class="page">
  <PageHeader title="Test-lab" crumb="Monitoring" sub={tr('Builds the installer ISO of a Hobnix branch and checks it in a virtual machine (stages 1 and 2).')}>
    {#snippet actions()}
      {#if on}
        <Button variant="primary" icon="flask" busy={jobRunning('testlab', ['run'])} busyLabel="Running…" tooltip={'Shows the plan first'}
                onclick={() => openPlan('testlab', ['run'], 'Run the test-lab on develop')}>{tr('Run on develop')}</Button>
      {/if}
    {/snippet}
  </PageHeader>

  {#if !on}
    <Banner tone="info">{tr('The test-lab is off. Turn on the capability testlab under Settings > Capabilities to use it here.')}</Banner>
  {:else}
    <div class="card elev-sm" style="padding:12px 14px">
      <Table id="testlab-results" {columns} rows={list} key="run" compact loading={!st.loaded}
             empty={tr(st.error ? 'The runs could not be read.' : 'No test-lab run yet.')}>
        {#snippet cell(r, col)}
          {#if col.key === 'result'}<StatusDot state={dot(r.result)} label={tr(r.result)} />
          {:else}<span class="c">{r[col.key]}</span>{/if}
        {/snippet}
      </Table>
    </div>
    <div class="muted"><code>hs testlab results</code> {tr('shows the same on the command line.')}</div>
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .muted { font-size: 12px; color: var(--fg-2); }
  .c { padding: 6px 8px; font-variant-numeric: tabular-nums; }
</style>
