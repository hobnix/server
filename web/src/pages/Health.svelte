<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows } from '../data.svelte.js';
  import { openPlan, ui } from '../ui.svelte.js';
  import { go } from '../route.svelte.js';
  import { agoShort } from '../format.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Banner from '../ui/Banner.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import Chip from '../ui/Chip.svelte';

  const health = poll('/api/sys/health/next', 15000);
  const hlist = poll('/api/sys/health/list', 15000);
  const jobs = poll('/api/sys/jobs/list', 30000);
  const status = poll('/api/sys/status', 30000);

  // A problem line is one sentence that ends with its own pointer ("... Details: journalctl -u hs-backup"): the sentence is the title,
  // the pointer the second line; the icon and the colour follow what the sentence is about.
  const POINTER = /\s+(Details:|Try:|Run:|Look( at)?:|Start one:|Apply it:|Done with it\?|Replace it with:|Push them:|Set who may use it:|Fix:)\s*/;
  const ICONS = [
    [/backup|restore drill|off-site/i, 'cloud-arrow-up'], [/locked|unlock|passphrase/i, 'lock'], [/temp disk/i, 'usb'],
    [/disk|SMART|self-test|bulk|zfs|pool|scrub|parity|snapraid/i, 'hard-drive'], [/full|space|cache/i, 'database'],
    [/UPS|battery|power/i, 'lightning'], [/certificate|runs out|ran out|expired|expiry|YYYY/i, 'calendar-x'],
    [/share /i, 'folders'], [/checkout|commit|hs update|hs rebuild|git/i, 'git-branch'], [/failed|unit/i, 'gear-six'],
  ];
  const SEVERE = /BAD|failed|errors?\b|expired|ran out|not healthy|DEGRADED|FAULTED|is locked|are locked|battery is low|power is out|open to everyone/i;
  // The `hs sys` flow that fixes a problem, where there is one (the problem texts are the ones of scripts/health-check.sh). Everything else keeps its
  // pointer text only: there is no safe single button for it (a failed unit, a full disk, an open share, a UPS, a certificate).
  const FIXES = [
    [/^no backup has finished yet|^last successful backup is \d+ hours old/, () => ['backup', ['now'], 'Back up now', 'Back up now']],
    [/container restore drill/, null],
    [/restore drill has succeeded|last successful restore drill/, () => ['backup', ['drill'], 'Restore drill', 'Restore drill']],
    [/off-site copy of the backup is more than/, () => ['backup', ['offsite-now'], 'Copy to the off-site repository', 'Copy off-site']],
    [/^ZFS pool (\S+) has never finished a scrub|^the last scrub of ZFS pool (\S+) finished/, (m) => ['system', ['scrub', '--pool', m[1] ?? m[2]], `Scrub ${m[1] ?? m[2]}`, 'Start a scrub']],
    [/SnapRAID scrub/, () => ['system', ['scrub', '--pool', 'bulk'], 'Scrub bulk', 'Start a scrub']],
    [/^temp disk ([a-z0-9][a-z0-9-]*) has been mounted/, (m) => ['disk', [m[1], 'temp-eject'], `Eject ${m[1]}`, 'Eject']],
  ];
  function fixFor(text) {
    for (const [re, make] of FIXES) {
      const m = re.exec(text);
      if (m) {
        if (!make) return null;
        const [area, args, title, label] = make(m);
        return { area, args, title, label };
      }
    }
    return null;
  }
  function describe(text, fix, since = '', told = '') {
    const m = text.match(POINTER);
    const head = (m ? text.slice(0, m.index) : text).replace(/[.\s]+$/, '');
    const how = m ? text.slice(m.index).trim() : '';
    return {
      title: head.charAt(0).toUpperCase() + head.slice(1),
      how: how && how !== fix ? how : '',
      fix,
      act: fixFor(text),
      icon: (ICONS.find(([re]) => re.test(text)) ?? [null, 'warning'])[1],
      bad: SEVERE.test(text),
      since: agoShort(since),
      told: told && told !== '-' ? told.split(',') : [],
    };
  }
  // problem, next (the command that helps)
  // id, problem, acked|-, since (epoch seconds), channels told (comma separated or -; both trailing columns are missing from an older server) (every active problem, also the acknowledged ones, which `health/next` no longer lists). Without the list the
  // page shows the plain problems, as before, and no acknowledge buttons.
  const nextOf = $derived(Object.fromEntries(rows(health).map((r) => [r[0], r[1]])));
  const withAck = $derived(hlist.loaded && !hlist.error && rows(hlist).length > 0);
  const problems = $derived(withAck
    ? rows(hlist).map((r) => ({ ...describe(r[1], nextOf[r[1]] ?? '', r[3], r[4]), id: r[0], acked: r[2] === 'acked' }))
    : rows(health).map((r) => ({ ...describe(r[0], r[1]), id: '', acked: false })));
  const answered = $derived(health.loaded && !health.error);
  const paused = $derived(rows(hlist).some((r) => r[0] === 'mitigation:paused'));

  // unit, description, next run, last run, result
  const run = $derived(rows(jobs).find((r) => /^hs-health-check/.test(r[0])));
  const sub = $derived([run && run[3] && run[3] !== '-' ? `checked ${run[3]}` : '', run && run[2] && run[2] !== '-' ? `next ${run[2]}` : '', 'a push goes out only when the set of problems changes'].filter(Boolean).join(' · '));

  // the checks that pass, taken from the status facts (nothing is listed that the status does not say)
  const checks = $derived.by(() => {
    const m = {};
    const js = [];
    for (const r of rows(status)) { if (r[0] === 'job') js.push(r.slice(1)); else m[r[0]] ??= r.slice(1); }
    const out = [];
    if (m.backup?.[0] === 'ok') { const h = Number(m.backup[1]) / 3600; out.push(['Backup', isNaN(h) ? 'ok' : `ok · ${h < 48 ? `${Math.floor(h)} h` : `${Math.floor(h / 24)} d`} ago`]); }
    for (const [unit, res, last] of js) if (res === 'ok') out.push([/sync/.test(unit) ? 'Parity sync' : /scrub/.test(unit) ? 'Scrub' : unit, last]);
    if (m.cache) out.push(['Upload cache', m.cache[1] ? `${m.cache[1]} %` : m.cache[0]]);
    if (m.hottest && Number(m.hottest[1]) < 55) out.push(['Disk temperatures', `max ${m.hottest[1]} °C`]);
    if (m.smart && !m.smart[1]) out.push(['Disk health', `${m.smart[0]} disks`]);
    if (m.instances && m.instances[0] === m.instances[1]) out.push(['Instances', `${m.instances[0]} running`]);
    if (m.encryption?.[0] === 'open') out.push(['Encryption', 'open']);
    return out;
  });

  // grouped as the design shows them (storage, backup, system, network) and each with the page of the object it is about
  const GROUPS = [['Storage', 'hard-drive', ['hard-drive', 'database', 'lock', 'usb', 'folders']], ['Backup', 'cloud-arrow-up', ['cloud-arrow-up']], ['Network', 'network', []], ['System', 'gear-six', ['lightning', 'calendar-x', 'git-branch', 'gear-six', 'warning']]];
  const OBJECT = { 'cloud-arrow-up': ['Backup', '/protection/backup'], 'hard-drive': ['Disks', '/storage/bulk/disks'], database: ['Pools', '/storage/bulk'], lock: ['Encryption', '/storage/encryption'], usb: ['Unassigned disks', '/storage/unassigned'], folders: ['Shares', '/storage/bulk/shares'], lightning: ['Hardware', '/monitoring/hardware'], 'calendar-x': ['Expiry dates', '/protection/expiry'] };
  const groups = $derived(GROUPS.map(([name, icon, icons]) => ({ name, icon, items: problems.filter((p) => icons.includes(p.icon)) })).filter((g) => g.items.length));
</script>

<div class="page">
  <PageHeader title="Health" crumb="{ui.host} / Health" {sub}>
    {#snippet actions()}
      <button class="btn btn-secondary" use:tip={'Send a test message to the push address'} onclick={() => openPlan('admin', ['test-push'], 'Test push message')}><i class="ph ph-bell-ringing"></i>Send test push</button>
      <button use:tip={'Check everything now and list the problems'} class="btn btn-primary" onclick={() => openPlan('jobs', ['run', 'hs-health-check.service'], 'Health check')}><i class="ph ph-shield-check"></i>Run health check</button>
    {/snippet}
  </PageHeader>

  {#if paused}
    <Banner tone="warn" icon="pause-circle">Sync, scrub and the cache mover are paused. Fix the cause first, then lift the pause.
      {#snippet action()}<button class="btn btn-primary sm" use:tip={'Shows the plan first'} onclick={() => openPlan('health', ['resume'], 'Resume the bulk jobs')}><i class="ph ph-play"></i>Resume</button>{/snippet}
    </Banner>
  {/if}

  <PageState loading={!health.loaded} error={health.error?.message ?? ''} hasData={health.data != null} empty={answered && !problems.length}
             emptyIcon="shield-check" emptyTitle="No problems" emptyText="The last health check found nothing to fix. It runs every 15 minutes.">
    {#each groups as g}
      <div class="card grp">
        <div class="gh"><i class="ph ph-{g.icon}"></i><b>{g.name}</b><span class="cnt">{g.items.length}</span></div>
        {#each g.items as p}
          <div class="problem" class:acked={p.acked}>
            <StatusDot state={p.acked ? 'off' : p.bad ? 'bad' : 'warn'} bare label={p.acked ? 'acknowledged' : p.bad ? 'severe' : 'warning'} />
            <div class="tx">
              <div class="ti">{p.title}</div>
              {#if p.how}<div class="how">{p.how}</div>{/if}
              <div class="meta">
                {#if p.acked}<Chip>acknowledged</Chip>{/if}
                {#if p.since}<span class="when" use:tip={'First seen by the health check'}>first seen {p.since}</span>{/if}
                {#if p.id && !p.acked}<span class="when" use:tip={'The channels that took the last message about this problem'}>{p.told.length ? `told: ${p.told.join(', ')}` : 'no message sent yet'}</span>{/if}
                {#if OBJECT[p.icon]}<button use:tip={'Open the page of the thing this problem is about'} class="lnk" onclick={() => go(OBJECT[p.icon][1])}>{OBJECT[p.icon][0]}<i class="ph ph-arrow-right"></i></button>{/if}
                {#if p.fix}<code class="chip">{p.fix}</code>{/if}
              </div>
            </div>
            <div class="acts">
              {#if p.id && p.acked}<button class="btn btn-ghost sm" use:tip={'Report it again and count it'} onclick={() => openPlan('health', ['unack', p.id], 'Undo acknowledge')}>Undo</button>
              {:else if p.id}<button class="btn btn-ghost sm" use:tip={'Silent until the problem is gone'} onclick={() => openPlan('health', ['ack', p.id], 'Acknowledge')}>Acknowledge</button>{/if}
              {#if p.act && !p.acked}<button class="btn btn-primary sm" use:tip={`Shows the plan first: ${p.act.title}`} onclick={() => openPlan(p.act.area, p.act.args, p.act.title)}>{p.act.label}</button>{/if}
            </div>
          </div>
        {/each}
      </div>
    {/each}
  </PageState>

  <div class="card">
    <div class="gh"><i class="ph ph-check-circle"></i><b>Passing checks</b></div>
    {#if checks.length}
      <div class="grid2">
        {#each checks as [name, meta]}
          <div class="crow"><i class="ph ph-check ok"></i><span class="grow">{name}</span><span class="meta2">{meta}</span></div>
        {/each}
      </div>
    {:else}
      <div class="meta2">{status.loaded ? 'Not available yet.' : 'Loading…'}</div>
    {/if}
  </div>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .grp { padding: 0; gap: 0; }
  .gh { display: flex; align-items: center; gap: 8px; padding: 12px 16px; border-bottom: 1px solid var(--line); font-size: 14px; }
  .gh i { color: var(--fg-3); }
  .cnt { font: 11px var(--mono); color: var(--fg-2); background: var(--panel-3); padding: 0 6px; }
  .problem { display: flex; align-items: flex-start; gap: 12px; padding: 12px 16px; border-bottom: 1px solid var(--line); flex-wrap: wrap; }
  .problem:last-child { border-bottom: 0; }
  .problem.acked { opacity: 0.6; }
  .tx { flex: 1 1 320px; min-width: 0; }
  .ti { font-size: 14px; }
  .how { font-size: 12px; color: var(--fg-3); margin-top: 2px; word-break: break-word; }
  .meta { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-top: 6px; }
  .when { font-size: 12px; color: var(--fg-3); }
  .lnk { all: unset; cursor: pointer; font-size: 12px; color: var(--accent); display: inline-flex; gap: 4px; align-items: center; }
  .lnk:focus-visible { outline: 2px solid var(--accent); }
  .chip { font: 12px var(--mono); padding: 3px 8px; background: var(--panel-2); color: var(--fg-2); white-space: nowrap; }
  .acts { display: flex; gap: 8px; align-items: center; }
  .card > .grid2, .card > .meta2 { margin: 12px 16px; }
  .grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); column-gap: 28px; }
  .crow { display: flex; align-items: center; gap: 10px; padding: 6px 0; border-bottom: 1px solid var(--line); }
  .crow .ok { color: var(--ok); }
  .grow { flex: 1; }
  .meta2 { font-size: 11.5px; color: var(--fg-3); }
</style>
