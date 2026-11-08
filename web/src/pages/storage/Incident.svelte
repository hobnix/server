<script>
  // Storage > Incident: a degraded pool, a missing pool disk or a failing disk, step by step (hobnix/server#255). Everything comes from
  // `hs sys incident state` (scripts/storage-incident.sh --state); the page changes nothing by itself. Pausing the writing apps is a plan
  // (area `incident`); the replace is the existing Replace form of the pools (plan, typed disk name, job), so the destructive step is the same one.
  import PageHeader from '../../shell/PageHeader.svelte';
  import PageState from '../../shell/PageState.svelte';
  import Table from '../../shell/Table.svelte';
  import { StatusDot, Banner, Chip } from '../../ui/index.js';
  import Button from '../../ui/Button.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { go } from '../../route.svelte.js';
  import { openPlan, openCreate, jobRunning } from '../../ui.svelte.js';
  import ReplaceMember from '../../forms/storage/ReplaceMember.svelte';

  let { deck } = $props();
  const locked = $derived(!!deck?.data?.locked);

  const st = poll('/api/sys/incident/state', 10000);
  const lines = $derived(rows(st));
  const of = (tag) => lines.filter((r) => r[0] === tag);
  const none = $derived(st.loaded && (lines.length === 0 || lines[0][0] === 'ok'));
  const incidents = $derived(of('incident').map((r) => ({ id: r[1], pool: r[2], kind: r[3], severity: r[4], text: r[5] })));
  const members = $derived(of('member').map((r) => ({ pool: r[1], name: r[2], state: r[3], group: r[4], disk: r[5], why: r[6] })));
  const target = $derived(of('target').map((r) => ({ pool: r[1], member: r[2], dev: r[3], disk: r[4] }))[0]);
  const shares = $derived(of('share').map((r) => ({ pool: r[1], name: r[2], path: r[3], impact: r[4] })));
  const apps = $derived(of('app').map((r) => ({ pool: r[1], name: r[2], state: r[3], via: r[4], writes: r[5] === 'yes' })));
  const progress = $derived(of('progress').map((r) => ({ pool: r[1], kind: r[2], pct: r[3] === '-' ? null : Number(r[3]), text: r[4] })));
  const paused = $derived(of('paused')[0]?.[1] === 'yes' ? of('paused')[0][2] : '');
  const free = $derived(of('free'));
  const steps = $derived(of('step').map((r) => ({ n: r[1], state: r[2], title: r[3] })));
  const next = $derived(of('next')[0]);
  const worst = $derived(incidents.some((i) => i.severity === 'error') ? 'bad' : 'warn');
  const writers = $derived(apps.filter((a) => a.writes && a.state === 'RUNNING'));
  const running = $derived(progress.length > 0);
  const snap = $derived(/^(data|parity)-\d+$/.test(target?.member ?? ''));
  const dot = (s) => (s === 'done' ? 'ok' : s === 'now' ? 'warn' : 'off');

  const shareCols = [{ key: 'name', label: 'Share' }, { key: 'path', label: 'Path', optional: true }, { key: 'impact', label: 'State' }];
  const appCols = [{ key: 'name', label: 'App' }, { key: 'state', label: 'State' }, { key: 'via', label: 'Uses' }];
  const replace = () => openCreate(ReplaceMember, { pool: target.pool, member: target.member, snap });
</script>

<PageHeader title="Incident" crumb="Storage" sub="A degraded pool or a failing disk: what happened, what it touches, the next safe step.">
  {#snippet actions()}
    <Button tooltip={'Back to the pools'} onclick={() => go('/storage/pools')}><i class="ph ph-cylinder"></i>Pools</Button>
  {/snippet}
</PageHeader>

<PageState loading={!st.loaded} hasData={st.loaded} empty={none} emptyIcon="shield-check" emptyTitle="No storage incident"
           emptyText="Every pool and every disk looks fine. This page opens by itself in the alert when that changes.">
  {#each incidents as i (i.id)}
    <Banner tone={i.severity === 'error' ? 'bad' : 'warn'}>{i.text}</Banner>
  {/each}

  <div class="card sect">
    <div class="sh"><b>Steps</b>{#if running}<Chip>replacement running</Chip>{/if}</div>
    <ol class="steps">
      {#each steps as s (s.n)}
        <li><StatusDot state={dot(s.state)} label={s.title + (s.state === 'optional' ? ' (optional)' : '')} /></li>
      {/each}
    </ol>
    {#if next}<p class="next"><b>Next safe step:</b> {next[2]}</p>{/if}
    <div class="acts">
      <Button variant="primary" icon="swap" disabled={locked || !target || running || !free.length} busy={jobRunning('pool', [target?.pool ?? '', 'replace'])}
        tooltip={running ? 'A replacement is already running' : !free.length ? 'Plug in a new disk that is at least as large first' : 'Pick the new disk, see the plan, type the disk name'} onclick={replace}>Replace the disk…</Button>
      {#if paused}
        <Button icon="play" tooltip={'Let the paused apps run again'} onclick={() => openPlan('incident', ['resume'], 'Resume apps')}>Resume apps</Button>
      {:else}
        <Button icon="pause" disabled={!writers.length} tooltip={writers.length ? 'Freeze the apps that write to an affected share (shows the plan first)' : 'No running app writes to an affected share'}
          onclick={() => openPlan('incident', ['pause'], 'Pause apps')}>Pause writing apps</Button>
      {/if}
    </div>
    {#if !free.length && !running}<p class="mute">No free disk that is large enough was found yet. Plug in the new disk; this page notices it.</p>{/if}
  </div>

  {#each progress as p}
    <div class="card sect">
      <div class="sh"><b>{p.kind === 'resilver' ? 'Resilver' : 'Rebuild'} of {p.pool}</b><span class="mute">{p.pct == null ? '' : `${p.pct} %`}</span></div>
      {#if p.pct != null}<div class="bar"><div class="fill" style="width:{p.pct}%"></div></div>{/if}
      <p class="mute">{p.text}. The pool stays usable; do not pull or unplug any disk until it is done.</p>
    </div>
  {/each}

  {#if members.length}
    <div class="card sect">
      <div class="sh"><b>The disk{members.length === 1 ? '' : 's'}</b></div>
      {#each members as m (m.pool + m.name)}
        <p><StatusDot state={m.state === 'ONLINE' ? 'warn' : 'bad'} label={`${m.name} in ${m.pool}: ${m.state.toLowerCase()}`} /> <span class="mute">{m.disk !== '-' ? m.disk : ''}{m.why !== '-' ? ` · SMART: ${m.why}` : ''}</span></p>
      {/each}
      {#if target}
        <p class="mute">{target.dev === '-' ? `${target.member} is gone: nothing to pull. Plug in its replacement.`
          : `To pull: ${target.disk} (${target.dev}). Check the serial number on the label; never go by the device letter alone.`}</p>
      {/if}
    </div>
  {/if}

  {#if shares.length}
    <div class="card sect">
      <div class="sh"><b>Affected shares</b></div>
      <Table id="incident-shares" columns={shareCols} rows={shares} key="name" compact empty="None.">
        {#snippet cell(r, col)}
          {#if col.key === 'name'}{r.name}
          {:else if col.key === 'path'}<code>{r.path}</code>
          {:else}<StatusDot state={r.impact === 'unavailable' ? 'bad' : 'warn'} label={r.impact === 'unavailable' ? 'files not reachable' : 'readable, no redundancy'} />{/if}
        {/snippet}
      </Table>
    </div>
  {/if}

  {#if apps.length}
    <div class="card sect">
      <div class="sh"><b>Affected apps</b>{#if paused}<span class="mute">paused by you: {paused}</span>{/if}</div>
      <Table id="incident-apps" columns={appCols} rows={apps} key="name" compact empty="None.">
        {#snippet cell(r, col)}
          {#if col.key === 'name'}{r.name}
          {:else if col.key === 'state'}<StatusDot state={r.state === 'RUNNING' ? 'ok' : 'off'} label={r.state.toLowerCase()} />
          {:else}{r.via === 'pool' ? 'lives on this pool' : `share ${r.via}`}{r.writes ? ' (writes)' : ''}{/if}
        {/snippet}
      </Table>
      <p class="mute">Pausing is only a suggestion: nothing is stopped unless you press the button. A paused app keeps its memory and carries on after Resume.</p>
    </div>
  {/if}
</PageState>

<style>
  .card { margin-bottom: 14px; }
  .sect { padding: 12px 14px; gap: 8px; }
  .sh { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .steps { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
  .next { margin: 4px 0 0; }
  .acts { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 6px; }
  .mute { color: var(--fg-3); font-size: 12px; margin: 0; }
  .bar { height: 8px; background: var(--line); border-radius: var(--r); overflow: hidden; }
  .fill { height: 100%; background: var(--accent); }
  code { font-size: 12px; }
</style>
