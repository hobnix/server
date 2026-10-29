<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import { poll, rows } from '../data.svelte.js';
  import { openCreate, openPlan } from '../ui.svelte.js';
  import ExpiryForm from '../forms/ops/ExpiryForm.svelte';
  import Table from '../shell/Table.svelte';
  import { go } from '../route.svelte.js';

  // days left sorts as a number (an invalid date has none and goes last)
  const columns = [
    { key: 'name', label: 'What' },
    { key: 'date', label: 'Expires' },
    { key: 'days', label: 'Left', sort: 'num', width: '200px' },
    { key: 'note', label: 'Note' },
    { key: 'rm', label: '', sort: false },
  ];

  const ex = poll('/api/sys/expiry/list', 10000);

  // name, date (ISO), days left or "-", state (ok|soon|due|expired|invalid), how to renew
  const items = $derived(rows(ex).map((r) => {
    const d = r[2] === undefined || r[2] === '-' || isNaN(r[2]) ? null : Number(r[2]);
    return { name: r[0], date: r[1], days: d, state: r[3], note: r[4] ?? '' };
  }));
  // The certificates, read only (the Certificates page under Identity owns them): key, value rows of `sys dc state`; no domain controller = nothing to show
  const dc = poll('/api/sys/dc/state', 30000);
  const c = $derived(Object.fromEntries(rows(dc).map((r) => [r[0], r[1] ?? ''])));
  const cDays = $derived(c.days_left !== undefined && c.days_left !== '' && !isNaN(c.days_left) ? Number(c.days_left) : null);
  const certs = $derived([
    ...(c.ca === 'yes' && c.ca_until ? [{ what: 'CA of this setup', until: c.ca_until, days: null }] : []),
    ...(c.cert === 'ok' ? [{ what: `Certificate of ${c.dc && c.dc !== '-' ? c.dc : 'the domain controller'}`, until: c.valid_until, days: cDays }] : []),
  ]);
  const warn = (i) => i.state !== 'ok';
  // The bar shows the time left on a one-year scale (the list holds no start date).
  const pct = (i) => (i.days === null ? 0 : Math.min(100, Math.max(i.days <= 0 ? 0 : 3, Math.round((i.days / 365) * 100))));
  const left = (i) => (i.days === null ? 'invalid' : i.days < 0 ? `${-i.days} d ago` : `${i.days} d`);
  const color = (i) => (warn(i) ? 'var(--st-warn)' : 'var(--color-accent-500)');
</script>

<div class="page">
  <PageHeader title="Expiry dates" crumb="Protection" sub="The health check warns 30 and 7 days before.">
    {#snippet actions()}<button class="btn btn-primary" use:tip={'Write down something that runs out'} onclick={() => openCreate(ExpiryForm)}><i class="ph ph-plus"></i>Add</button>{/snippet}
  </PageHeader>

  <div class="card elev-sm" style="padding:12px 14px">
    <Table id="expiry" {columns} rows={items} key="name" loading={!ex.loaded} empty={ex.error ? 'The list could not be read.' : 'Nothing is entered yet. On the server: hs expiry add <name> <YYYY-MM-DD>.'}>
      {#snippet cell(i, col)}
        {#if col.key === 'name'}{i.name}
        {:else if col.key === 'date'}<span class="date">{i.date}</span>
        {:else if col.key === 'days'}
          <div class="bar">
            <div class="track"><div class="fill" style="width:{pct(i)}%;background:{color(i)}"></div></div>
            <span class="left" style="color:{warn(i) ? 'var(--st-warn)' : 'var(--color-neutral-300)'}">{left(i)}</span>
          </div>
        {:else if col.key === 'note'}<span class="note">{i.note}</span>
        {:else}<button class="btn btn-ghost btn-icon rm" use:tip={`Remove ${i.name} from the list`} aria-label="Remove {i.name}" onclick={() => openPlan('expiry', ['remove', i.name], 'Remove ' + i.name)}><i class="ph ph-x"></i></button>{/if}
      {/snippet}
    </Table>
  </div>

  {#if certs.length}
    <div class="card elev-sm" style="padding:12px 14px;gap:6px">
      <div class="crow"><b>Certificates</b><span class="grow"></span><button use:tip={'Open the certificates page'} class="btn btn-ghost sm" onclick={() => go('/identity/certificates')}>Manage<i class="ph ph-arrow-right"></i></button></div>
      {#each certs as k}
        <div class="crow"><span>{k.what}</span><span class="grow"></span><span class="date">{k.until}</span>
          {#if k.days !== null}<span class="left" style="color:{k.days < 60 ? 'var(--st-warn)' : 'var(--color-neutral-300)'}">{k.days < 0 ? `${-k.days} d ago` : `${k.days} d`}</span>{/if}</div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .crow { display: flex; align-items: center; gap: 12px; font-size: 13px; }
  .grow { flex: 1; }
  .date { color: var(--color-neutral-300); white-space: nowrap; }
  .note { color: var(--color-neutral-400); }
  .bar { display: flex; align-items: center; gap: 8px; }
  .track { flex: 1; height: 5px; border-radius: var(--r); background: var(--color-neutral-800); }
  .fill { height: 5px; border-radius: var(--r); }
  .left { width: 64px; text-align: right; white-space: nowrap; }
  .rm { width: 26px; height: 26px; color: var(--color-neutral-400); }
</style>
