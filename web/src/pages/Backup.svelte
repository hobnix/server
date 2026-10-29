<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows, refresh } from '../data.svelte.js';
  import { bytes, ago } from '../format.js';
  import { openPlan, openCreate, ui } from '../ui.svelte.js';
  import RestoreFiles from '../forms/backup/RestoreFiles.svelte';
  import SetupDisk from '../forms/backup/SetupDisk.svelte';
  import { get } from '../api.js';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import Switch from '../ui/Switch.svelte';
  import Banner from '../ui/Banner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import { link } from './instances/ct.js';

  let { deck } = $props();
  // locked storage: the share and instance rows cannot be read (and their switches would act on nothing), so they are left out
  const locked = $derived(!!deck?.data?.locked);

  const st = poll('/api/sys/backup/state', 15000);
  const ov = poll('/api/sys/backup/overview', 30000);
  const snS = poll('/api/sys/backup/snapshots?tag=shares', 30000);
  const snH = poll('/api/sys/backup/snapshots?tag=host', 30000);

  // key, value rows
  const s = $derived(Object.fromEntries(rows(st).map((r) => [r[0], r[1] ?? ''])));
  const configured = $derived(s.configured === 'yes');
  // kind (shares|sensitive|ct|always), name, on|off, bytes or -
  const items = $derived(rows(ov).map((r) => ({ kind: r[0], name: r[1], on: r[2] === 'on', size: r[3] })).filter((i) => !locked || i.kind === 'always'));
  // id, time (UTC), tags: shares and host together, newest first
  const points = $derived([...rows(snS), ...rows(snH)].map((r) => ({ id: r[0], time: r[1], tags: r[2] })).sort((a, b) => (a.time < b.time ? 1 : a.time > b.time ? -1 : 0)));
  const snapsLoaded = $derived(snS.loaded && snH.loaded);
  const snapsError = $derived(snS.error && snH.error);

  // find a file in every snapshot: snapshot, time, path, type, bytes
  let q = $state('');
  let finding = $state(false);
  let found = $state(null);
  let findError = $state('');
  const findOk = $derived(/^[^\x00-\x1f/\\*?[\]]{2,80}$/.test(q.trim()));
  async function find() {
    if (!findOk || finding) return;
    finding = true; findError = ''; found = null;
    try {
      const r = await get(`/api/sys/backup/find/${encodeURIComponent(q.trim())}`);
      found = (r?.rows ?? []).map((x) => ({ snap: x[0], time: x[1], path: x[2], type: x[3], size: Number(x[4]) }));
    } catch (e) { findError = e.message || 'The search failed (it can take a while on a big backup).'; }
    finally { finding = false; }
  }

  const age = (v) => (v && !isNaN(v) ? ago(Math.max(0, Math.floor(Date.now() / 1000) - Number(v))) : '');
  // "today 04:00", "tomorrow 04:00", "Sat, 10 Oct 04:00"
  const when = (v) => {
    if (!v || isNaN(v)) return '–';
    const d = new Date(Number(v) * 1000);
    const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
    const diff = Math.round((day(d) - day(new Date())) / 86400000);
    const hm = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
    const lab = diff === 0 ? 'today' : diff === 1 ? 'tomorrow' : diff === -1 ? 'yesterday' : d.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' });
    return `${lab} ${hm}`;
  };
  const dot = (v) => (v === 'ok' || v === 'yes' ? 'ok' : v ? 'bad' : 'off');
  const head = $derived(!st.loaded ? 'Loading…' : !configured ? 'No backup set up'
    : s.status === 'failed' ? 'Last backup failed' : s.last_ok ? 'Last backup ok' : 'No backup yet');
  const sub = $derived([s.last_ok ? when(s.last_ok) : '', s.status === 'failed' && s.last_try ? `last try ${age(s.last_try)}` : '', s.next ? `next ${when(s.next)}` : ''].filter(Boolean).join(' · '));
  const facts = $derived([
    ['Backup disk', `${s.disk === 'present' ? 'present' : s.disk || '–'}${s.vault === 'closed' ? ' · vault closed' : ''}`, s.disk === 'present' ? 'ok' : 'warn'],
    ['Repository', `${s.repo_size || '–'}${s.used_pct ? ` · disk ${s.used_pct} % used` : ''}`, s.repo_size ? 'ok' : 'off'],
    ['Restore points', s.snapshots || '–', 'off'],
    ['Off-site copy', s.offsite ? `${s.offsite}${s.offsite_ok ? (s.offsite_ok === 'ok' ? ' · ok' : ' · failed') : ''}` : 'not set', s.offsite ? dot(s.offsite_ok) : 'off'],
    ['Restore drill', s.last_drill ? `${s.drill_ok === 'ok' ? 'passed' : s.drill_ok || '–'} · ${age(s.last_drill)}` : 'never', s.last_drill ? dot(s.drill_ok) : 'off'],
    ['Last try', s.last_try ? `${when(s.last_try)} · ${s.status === 'failed' ? 'failed' : 'ok'}` : '–', s.last_try ? (s.status === 'failed' ? 'bad' : 'ok') : 'off'],
    ...(s.drill_ct_name ? [['Instance drill', `${s.drill_ct_name} · ${s.drill_ct_ok === 'ok' ? 'ok' : s.drill_ct_ok || '–'}`, dot(s.drill_ct_ok)]] : []),
  ]);
  // actions that need the backup disk: say why one is not possible
  const why = $derived(!st.loaded ? 'Loading…' : !configured ? 'The backup is not set up yet' : s.vault === 'closed' ? 'The vault is closed: unlock it first' : s.disk !== 'present' ? 'The backup disk is not plugged in' : '');
  const browsing = $derived(s.browse === 'on');
  const tipWhy = (t) => (why ? `${t} (${why})` : t);
  const headDot = $derived(!configured ? 'off' : s.status === 'failed' ? 'bad' : s.last_ok ? 'ok' : 'warn');
  const itemLink = (i) => (i.kind === 'ct' ? link('/instances', 'instances', i.name) : link('/storage/bulk/shares', 'shares', i.name));
  const toggle = (i) => openPlan('backup', ['toggle', '--name', i.name, '--kind', i.kind, '--to', i.on ? 'off' : 'on'], `${i.on ? 'Leave out of' : 'Put into'} the backup: ${i.name}`);
  const kindName = { shares: 'share', sensitive: 'sensitive share', ct: 'instance', always: 'always' };
  const kindIcon = { shares: 'folder', sensitive: 'folder-lock', ct: 'cube', always: 'desktop-tower' };

  const columns = [
    { key: 'name', label: 'Item' }, { key: 'kind', label: 'Kind', optional: true, value: (i) => kindName[i.kind] ?? i.kind },
    { key: 'size', label: 'Size', sort: 'num', optional: true, value: (i) => Number(i.size) }, { key: 'on', label: 'In the backup', value: (i) => (i.kind === 'always' ? 'always' : i.on ? 'on' : 'off') },
  ];
  const pointCols = [
    { key: 'id', label: 'ID' }, { key: 'time', label: 'Time (UTC)' }, { key: 'tags', label: 'Tags', value: (p) => p.tags.split(',').join(' · ') },
  ];
  const foundCols = [
    { key: 'snap', label: 'Restore point' }, { key: 'time', label: 'Time (UTC)' }, { key: 'path', label: 'Path' }, { key: 'size', label: 'Size', sort: 'num', value: (f) => (f.type === 'file' ? f.size : NaN) },
  ];
</script>

<PageHeader title="Backup" crumb="{ui.host} › Protection" sub="restic on the backup disk · 7 daily / 4 weekly / 6 monthly · the one place that decides what is in the backup">
  {#snippet actions()}
    <button class="btn" disabled={!!why} use:tip={tipWhy('Read part of the stored data and check it')} onclick={() => openPlan('backup', ['verify'], 'Verify the backup')}><i class="ph ph-seal-check"></i>Verify</button>
    <button class="btn" disabled={!!why} use:tip={tipWhy('Give space back: delete leftovers of a failed run, apply the retention, prune')} onclick={() => openPlan('backup', ['prune'], 'Free space on the backup disk')}><i class="ph ph-broom"></i>Free space</button>
    <button class="btn" disabled={!!why} use:tip={tipWhy('Restore a few random files and compare them with the originals')} onclick={() => openPlan('backup', ['drill'], 'Restore drill')}><i class="ph ph-first-aid-kit"></i>Restore drill</button>
    <button class="btn" disabled={!!why && !browsing} use:tip={browsing ? 'Stop showing the backup as a read-only share' : tipWhy('Show the whole backup as a read-only share')} onclick={() => openPlan('backup', ['browse', '--to', browsing ? 'off' : 'on'], browsing ? 'Stop browsing the backup' : 'Browse the backup')}><i class="ph ph-folder-open"></i>{browsing ? 'Stop browsing' : 'Browse'}</button>
    <button class="btn btn-primary" disabled={!!why} use:tip={tipWhy('Back up right now')} onclick={() => openPlan('backup', ['now'], 'Back up now')}><i class="ph ph-cloud-arrow-up"></i>Back up now</button>
  {/snippet}
</PageHeader>

<PageState loading={!st.loaded} error={st.error?.message} hasData={st.data != null} retry={() => refresh(['/api/sys/backup/state'])}>
  {#if !configured}
    <div class="card">
      <EmptyState icon="cloud-slash" title="No backup set up" text="Nothing is backed up yet. Make a free disk the backup disk: it is erased, the plan shows what happens first, and the backup password is made inside the vault.">
        {#snippet action()}<button class="btn btn-primary" use:tip={'Make a free disk the backup disk (it is erased)'} onclick={() => openCreate(SetupDisk)}><i class="ph ph-hard-drive"></i>Set up backup disk…</button>{/snippet}
      </EmptyState>
    </div>
  {:else}
    <div class="card status">
      <div class="lead">
        <StatusDot state={headDot} large bare label={head} />
        <div><div class="big">{head}</div>{#if sub}<div class="small">{sub}</div>{/if}</div>
      </div>
      <div class="facts">
        {#each facts as f}
          <div class="fact"><StatusDot state={f[2]} bare label={f[1]} /><span class="fl">{f[0]}</span><span class="fv">{f[1]}</span></div>
        {/each}
      </div>
      <div class="offs">
        {#if s.offsite}
          <button class="btn sm" disabled={!!why} use:tip={tipWhy('Copy the new backups to the off-site repository now')} onclick={() => openPlan('backup', ['offsite-now'], 'Copy to the off-site repository')}><i class="ph ph-arrows-clockwise"></i>Copy off-site now</button>
          <button class="btn sm btn-ghost" use:tip={'Stop copying off site (what is there stays)'} onclick={() => openPlan('backup', ['offsite-off'], 'Switch the off-site copy off')}><i class="ph ph-cloud-slash"></i>Switch off</button>
        {:else}
          <span class="muted">Off-site copy: set one on the server with <span class="mono">hs backup offsite set &lt;repo&gt;</span> (an address can carry a password, so it is not typed here).</span>
        {/if}
      </div>
    </div>

    <div class="card tc">
      <div class="ctl"><b>What is in the backup</b><span class="cs">the switch here is the only place that decides it; the host files are always in</span></div>
      {#if locked}<Banner tone="warn">The storage is locked: the shares and instances are not listed until it is unlocked.</Banner>{/if}
      <Table id="backup-items" {columns} rows={items} loading={!ov.loaded} empty={ov.error ? 'This could not be read (is the backup disk there?).' : 'Nothing listed.'}>
        {#snippet cell(i, col)}
          {#if col.key === 'name'}<span class="row7"><i class="ph ph-{kindIcon[i.kind] ?? 'folder'}"></i>{#if i.kind === 'always'}{i.name}{:else}<a {...itemLink(i)} use:tip={i.kind === 'ct' ? 'Open the instance' : 'Open the share'}>{i.name}</a>{/if}</span>
          {:else if col.key === 'kind'}<span class="n400">{kindName[i.kind] ?? i.kind}</span>
          {:else if col.key === 'size'}{i.size && i.size !== '-' && !isNaN(i.size) ? bytes(Number(i.size)) : '–'}
          {:else if i.kind === 'always'}<span class="tag tag-accent">always</span>
          {:else}<span class="inc"><Switch bind:checked={() => i.on, () => toggle(i)} label="{i.name} in the backup" /><span class="n400">{i.on ? 'on' : 'off'}</span></span>{/if}
        {/snippet}
      </Table>
    </div>

    <div class="card tc">
      <div class="ctl">
        <b>Restore points</b>{#if s.snapshots}<span class="cs">{s.snapshots} in the repository</span>{/if}
        <button class="btn sm" use:tip={'Bring files back into the share restored; originals stay'} style="margin-left:auto" onclick={() => openCreate(RestoreFiles)}><i class="ph ph-arrow-counter-clockwise"></i>Restore files…</button>
      </div>
      <Table id="backup-points" columns={pointCols} rows={points} loading={!snapsLoaded}
             empty={snapsError ? 'The restore points could not be read (backup disk missing or storage locked).' : 'No restore points yet.'}>
        {#snippet cell(p, col)}
          {#if col.key === 'id'}<span class="mono">{p.id}</span>
          {:else if col.key === 'time'}{p.time}
          {:else}<span class="n300">{p.tags.split(',').join(' · ')}</span>{/if}
        {/snippet}
      </Table>
    </div>

    <div class="card tc">
      <div class="ctl"><b>Find a file</b><span class="cs">in every restore point</span></div>
      <form class="findrow" onsubmit={(e) => { e.preventDefault(); find(); }}>
        <input class="input" bind:value={q} placeholder="Part of a file name, e.g. Rechnung" maxlength="80" autocomplete="off" spellcheck="false" aria-label="Part of a file name" />
        <button use:tip={!findOk ? 'Type at least part of a file name first' : 'Look for this name in all backups'} class="btn" type="submit" disabled={!findOk || finding}><i class="ph ph-magnifying-glass"></i>{finding ? 'Searching…' : 'Find'}</button>
      </form>
      {#if findError}<div class="muted">{findError}</div>{/if}
      {#if found}
        <Table id="backup-found" columns={foundCols} rows={found} empty="Nothing found.">
          {#snippet cell(f, col)}
            {#if col.key === 'snap'}<span class="mono">{f.snap}</span>
            {:else if col.key === 'time'}{f.time}
            {:else if col.key === 'path'}<span class="n300" style="overflow-wrap:anywhere">{f.path}{f.type === 'dir' ? '/' : ''}</span>
            {:else}{f.type === 'file' ? bytes(f.size) : ''}{/if}
          {/snippet}
        </Table>
        {#if found.length >= 200}<div class="muted">Only the first 200 hits are shown: use a longer word.</div>{/if}
        <div class="muted">To bring a file back: Restore files… above, with the path and the restore point.</div>
      {/if}
    </div>
  {/if}
</PageState>

<style>
  .findrow { display: flex; gap: 8px; margin: 8px 0; }
  .findrow .input { flex: 1; min-width: 0; }
  .muted { font-size: 12px; color: var(--fg-3); }
  .status { flex-direction: row; flex-wrap: wrap; gap: 24px 28px; padding: 16px 18px; align-items: center; }
  .lead { flex: 1 1 260px; display: flex; align-items: center; gap: 14px; }
  .big { font-size: 20px; font-weight: 600; letter-spacing: -0.02em; }
  .small { font-size: 13px; color: var(--fg-3); }
  .offs { flex: 1 1 100%; display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  .facts { flex: 2 1 460px; display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); column-gap: 28px; }
  .fact { position: relative; display: flex; align-items: center; gap: 8px; padding: 6px 0; border-bottom: 1px solid var(--line); }
  .fl { width: 100px; flex: none; color: var(--fg-3); }
  .fv { flex: 1; min-width: 0; }
  .tc { padding: 12px 14px; }
  .ctl { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; margin-bottom: 6px; }
  .ctl b { font-size: 14px; font-weight: 600; }
  .cs { font-size: 12px; color: var(--fg-3); }
  .row7 { display: flex; align-items: center; gap: 7px; }
  .row7 i { color: var(--fg-3); }
  .inc { display: flex; align-items: center; gap: 10px; }
  .n300 { color: var(--fg-2); }
  .n400 { color: var(--fg-3); }
  .mono { font-size: 12px; }
</style>
