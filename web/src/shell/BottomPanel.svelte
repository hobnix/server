<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { onDestroy } from 'svelte';
  import { poll, rows } from '../data.svelte.js';
  import { get } from '../api.js';
  import { ui, tasks, track, openPlan } from '../ui.svelte.js';

  let { user = '' } = $props();

  let level = $state('warning');

  const tabs = [
    { id: 'tasks', label: 'Tasks', icon: 'list-checks' },
    { id: 'jobs', label: 'Jobs', icon: 'clock-counter-clockwise' },
    { id: 'logs', label: 'Logs', icon: 'scroll' },
    { id: 'events', label: 'Disk events', icon: 'hard-drive' },
    { id: 'reports', label: 'Reports', icon: 'file-text' },
  ];
  const reports = [
    { id: 'doctor', name: 'Doctor', desc: 'Checks the setup end to end and explains each finding.', cmd: 'hs sys system doctor' },
    { id: 'cleanup', name: 'Cleanup', desc: 'What could be removed: old generations, kept folders, images.', cmd: 'hs sys system cleanup' },
    { id: 'report', name: 'Report', desc: 'A plain-text overview to share when asking for help.', cmd: 'hs sys system report' },
    { id: 'config', name: 'Config', desc: 'The common settings from machine.toml.', cmd: 'hs sys system config' },
  ];
  const open = $derived(ui.panel.open);
  const tab = $derived(ui.panel.tab);

  // the counts on the tabs need the two lists even while another tab shows; the other tabs are read only while visible
  const running = poll('/api/sys/jobs/running', 5000);
  const jobs = poll('/api/sys/jobs/list', 15000);
  const logs = poll(() => (open && tab === 'logs' ? `/api/sys/logs/show?lines=150&since=today&level=${level}` : ''), 10000);
  const events = poll(() => (open && tab === 'events' ? '/api/sys/state/events?n=60' : ''), 15000);

  // tasks of this browser, plus jobs the server runs that were started elsewhere (a terminal, a timer)
  // the server names a unit with .service, a tracked task may not: compare without the suffix
  const bare = (u) => String(u).replace(/\.service$/, '');
  const others = $derived(rows(running).filter((r) => !tasks.list.some((t) => bare(t.unit) === bare(r[0]))).map((r) => ({ unit: r[0], title: r[1] || r[0], started: r[2], state: 'running', remote: true })));
  const all = $derived([...tasks.list, ...others]);
  const sel = $derived(tasks.list.find((t) => t.unit === tasks.selected));

  const jobRows = $derived(rows(jobs));
  const eventRows = $derived([...rows(events)].reverse());

  // `journalctl -o short-iso`: "2026-10-12T14:02:11+0200 host unit[pid]: message", newest first here
  const logLines = $derived((logs.data?.text ?? '').split('\n').filter(Boolean).reverse().map(parseLog));
  const LOGLINE = /^\S*T(\d\d:\d\d:\d\d)\S*\s+\S+\s+([^\s:[]+)(?:\[\d+\])?:?\s*(.*)$/;
  function parseLog(l) {
    const m = LOGLINE.exec(l);
    const msg = m ? m[3] : l;
    const lvl = /\b(error|err|fail|failed|crit|alert|emerg)\b/i.test(msg) ? 'error' : /\bwarn(ing)?\b/i.test(msg) ? 'warning' : 'info';
    return { t: m ? m[1] : '', unit: m ? m[2] : '', msg, lvl };
  }

  // a clock for the running durations
  let now = $state(Date.now());
  const tick = setInterval(() => { if (open && tab === 'tasks') now = Date.now(); }, 1000);
  onDestroy(() => clearInterval(tick));

  const dot = (r) => (r === 'ok' ? 'ok' : r === 'failed' ? 'bad' : r === 'running' ? 'run' : 'off');
  const label = (t) => (t.state === 'ok' ? 'ok' : t.state === 'failed' ? `failed (exit ${t.exit ?? '?'})` : t.state === 'unknown' ? 'gone' : 'running');
  const clock = (d) => (d instanceof Date ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : d);
  const span = (t) => {
    if (!(t.started instanceof Date)) return '–';
    const s = Math.max(0, Math.round(((t.ended ?? new Date(now)) - t.started) / 1000));
    return s < 60 ? `${s} s` : s < 3600 ? `${Math.round(s / 60)} min` : `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min`;
  };
  const select = (t) => { tasks.selected = t.unit; if (t.remote) track(t.unit, t.title); };
  const count = (id) => (id === 'tasks' ? String(all.length) : id === 'jobs' && jobs.loaded ? String(jobRows.length) : '');

  // reports: the text of a read, shown in place of the tiles
  let report = $state(null);                // { name, cmd, text, error, busy }
  async function showReport(r) {
    report = { name: r.name, cmd: r.cmd, text: '', error: '', busy: true };
    try {
      const d = await get(`/api/sys/system/${r.id}`);
      report = { ...report, text: (d.text ?? '').replace(/\x1b\[[0-9;]*m/g, '').trim() || 'The command printed nothing.', busy: false };
    } catch (e) {
      report = { ...report, error: e.message, busy: false };
    }
  }

  // the grip: drag to set the height (40 px up to 60 % of the window); dragged down to the bottom it collapses
  let dragging = $state(false);
  function grab(e) {
    if (e.button) return;
    e.preventDefault();
    dragging = true;
    const move = (ev) => {
      const h = Math.min(Math.max(window.innerHeight - ev.clientY, 40), Math.round(window.innerHeight * 0.6));
      if (h <= 60) ui.panel.open = false;
      else { ui.panel.open = true; ui.panel.height = h; }
    };
    const up = () => {
      dragging = false;
      removeEventListener('pointermove', move);
      removeEventListener('pointerup', up);
      removeEventListener('pointercancel', up);
    };
    addEventListener('pointermove', move);
    addEventListener('pointerup', up);
    addEventListener('pointercancel', up);
  }
</script>

<section class:dragging style="height:{open ? ui.panel.height : 40}px">
  <div class="grip" role="separator" aria-orientation="horizontal" aria-label="Resize the panel" onpointerdown={grab}><span></span></div>
  <div class="tabs">
    {#each tabs as t}
      <button class="tab" class:active={open && tab === t.id} onclick={() => { ui.panel.tab = t.id; ui.panel.open = true; }}>
        <i class="ph ph-{t.icon}"></i>{t.label}<span class="n">{count(t.id)}</span>
      </button>
    {/each}
    <span style="flex:1"></span>
    <span class="tag tag-neutral" style="padding:1px 8px;margin-right:8px">all nodes</span>
    <button use:tip={open ? 'Collapse the panel' : 'Expand the panel'} class="btn btn-ghost btn-icon" style="width:26px;height:26px;color:var(--color-neutral-400)" onclick={() => (ui.panel.open = !open)} aria-label={open ? 'Collapse' : 'Expand'}>
      <i class="ph ph-caret-{open ? 'down' : 'up'}"></i>
    </button>
  </div>

  {#if open}
    <div class="body">
      {#if tab === 'tasks'}
        {#if all.length === 0}
          <div class="empty">No tasks. A change you start here (Run now in Jobs, Run health check on the Summary) shows up here and keeps running on the server if you close the page.</div>
        {:else}
          <div class:split={!!sel}>
            <div class="tablescroll"><table class="table">
              <thead><tr><th>Started</th><th>Node</th><th>Unit</th><th>Task</th><th>Caller</th><th>Duration</th><th>Result</th></tr></thead>
              <tbody>
                {#each all as t}
                  <tr class="click" class:sel={t.unit === tasks.selected} tabindex="0" onclick={() => select(t)} onkeydown={(e) => { if (e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); select(t); } }}>
                    <td class="muted">{clock(t.started)}</td>
                    <td class="soft">{ui.host}</td>
                    <td class="mono unit">{t.unit}</td>
                    <td>{t.title}</td>
                    <td class="muted">{t.remote ? '–' : `${user} · web`}</td>
                    <td class="muted">{t.remote ? '–' : span(t)}</td>
                    <td><span class="res"><span class="dot {dot(t.state)}"></span>{label(t)}</span></td>
                  </tr>
                {/each}
              </tbody>
            </table></div>
            {#if sel}
              <div class="log tail">
                {#each sel.lines as l}<div>{l}</div>{:else}<div class="empty" style="padding:0">{sel.state === 'running' ? 'Waiting for output…' : 'No output.'}</div>{/each}
              </div>
            {/if}
          </div>
        {/if}
      {:else if tab === 'jobs'}
        {#if jobs.error && !jobs.data}<div class="empty">Jobs could not be read.</div>
        {:else}
        <div class="tablescroll"><table class="table">
          <thead><tr><th>Unit</th><th>Node</th><th>What it does</th><th>Last run</th><th>Next run</th><th>Result</th><th></th></tr></thead>
          <tbody>
            {#each jobRows as r}
              <tr>
                <td class="mono unit">{r[0]}</td><td class="soft">{ui.host}</td><td class="muted">{r[1]}</td><td class="muted">{r[3]}</td><td>{r[2]}</td>
                <td><span class="res"><span class="dot {dot(r[4])}"></span>{r[4]}</span></td>
                <td class="act"><button use:tip={'Run this job now (shows the plan first)'} class="btn btn-ghost" style="font-size:11.5px;padding:2px 6px" onclick={() => openPlan('jobs', ['run', r[0]], r[1] || r[0])}>Run now</button></td>
              </tr>
            {:else}
              <tr><td colspan="7" class="empty">{jobs.loaded ? 'No scheduled jobs.' : 'Loading…'}</td></tr>
            {/each}
          </tbody>
        </table></div>
        {/if}
      {:else if tab === 'logs'}
        <div class="bar">
          <label for="lvl">Show</label>
          <select id="lvl" class="input" style="width:auto;min-height:26px;padding:2px 8px;font-size:12px" bind:value={level}>
            <option value="err">errors</option><option value="warning">warnings and errors</option><option value="info">everything</option>
          </select>
          <span style="color:var(--color-neutral-500)">today, newest first</span>
        </div>
        <div class="loglist">
          {#each logLines as l}
            <div class="ll"><span class="lt">{l.t}</span><span class="lu">{l.unit}</span><span class="lv" class:warn={l.lvl === 'warning'} class:bad={l.lvl === 'error'}>{l.lvl}</span><span class="lm">{l.msg}</span></div>
          {:else}<div class="empty" style="padding:4px 0">{logs.loaded ? 'Nothing logged at this level today.' : 'Loading…'}</div>{/each}
        </div>
      {:else if tab === 'events'}
        <div class="tablescroll"><table class="table">
          <thead><tr><th>When</th><th>Disk</th><th>Event</th><th>Detail</th></tr></thead>
          <tbody>
            {#each eventRows as r}
              <tr><td class="muted">{r[0]}</td><td><code style="font-size:11.5px">{r[2]}</code></td><td><span class="tag tag-neutral" style="padding:0 7px">{r[1]}</span></td><td class="soft">{r[3]}</td></tr>
            {:else}
              <tr><td colspan="4" class="empty">{events.loaded ? 'No disk events yet.' : 'Loading…'}</td></tr>
            {/each}
          </tbody>
        </table></div>
      {:else if report}
        <div class="bar rbar">
          <button use:tip={'Back to the list of reports'} class="btn btn-ghost" style="font-size:12px;padding:2px 6px" onclick={() => (report = null)}><i class="ph ph-caret-left"></i>Reports</button>
          <span style="font-weight:500">{report.name}</span>
          <code style="font-size:11px;color:var(--color-neutral-500)">{report.cmd}</code>
        </div>
        {#if report.busy}<div class="empty">Running it on the server…</div>
        {:else if report.error}<div class="empty" style="color:var(--st-bad)">{report.error}</div>
        {:else}<pre class="log rep">{report.text}</pre>{/if}
      {:else}
        <div class="tiles">
          {#each reports as r}
            <div class="tile" role="button" tabindex="0" onclick={() => showReport(r)} onkeydown={(e) => (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), showReport(r))}>
              <span class="tn"><i class="ph ph-file-text" style="color:var(--color-accent)"></i>{r.name}</span>
              <span style="font-size:12px;color:var(--color-neutral-400)">{r.desc}</span>
              <code style="font-size:11px;color:var(--color-neutral-500)">{r.cmd}</code>
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</section>

<style>
  /* the bottom drawer (Jobs and Logs): one solid line on top, the same as the bar's bottom line */
  section { flex: none; display: flex; flex-direction: column; min-height: 0; background: var(--panel); border-top: 1px solid var(--line-2); position: relative; z-index: 4; }
  section.dragging { user-select: none; }
  .grip { height: 8px; flex: none; display: grid; place-items: center; cursor: row-resize; touch-action: none; }
  .grip span { width: 44px; height: 3px; background: var(--line-2); }
  .tabs { display: flex; align-items: center; gap: 2px; padding: 0 8px; border-bottom: 1px solid var(--line); flex: none; overflow-x: auto; overflow-y: hidden; }
  .tab { position: relative; display: flex; align-items: center; gap: 7px; padding: 6px 12px 8px; font: inherit; font-size: 12.5px; font-weight: 500; color: var(--fg-2); background: none; border: 0; cursor: pointer; white-space: nowrap; }
  .tab:hover { color: var(--fg); }
  .tab.active { color: var(--fg); }
  .tab.active::after { content: ''; position: absolute; left: 8px; right: 8px; bottom: 0; height: 2px; background: linear-gradient(90deg, var(--h2), var(--h1), var(--h4)); }
  .n { color: var(--fg-3); font-family: var(--mono); font-size: 11px; }
  .body { flex: 1; min-height: 0; overflow: auto; scrollbar-gutter: stable; font-size: 12px; }
  .bar { display: flex; align-items: center; gap: 8px; padding: 6px 14px; font-size: 12px; }
  .rbar { border-bottom: 1px solid var(--line); }
  .log { font-family: var(--mono); font-size: 11.5px; line-height: 1.5; }
  .rep { margin: 0; padding: 8px 14px; white-space: pre-wrap; color: var(--fg-2); font-family: var(--mono); }
  .loglist { padding: 6px 0; font-family: var(--mono); font-size: 12px; line-height: 1.75; }
  .ll { display: flex; gap: 14px; padding: 0 16px; }
  .ll:hover { background: var(--panel-2); }
  .lt { color: var(--fg-3); }
  .lu { width: 110px; flex: none; color: var(--fg-3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .lv { width: 52px; flex: none; color: var(--accent-ink); }
  .lv.warn { color: var(--warn-ink); }
  .lv.bad { color: var(--bad-ink); }
  .lm { color: var(--fg-2); min-width: 0; overflow-wrap: anywhere; }
  .split { display: grid; grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr); gap: 14px; align-items: stretch; height: 100%; grid-template-rows: minmax(0, 1fr); }
  .split .tablescroll { min-height: 0; overflow-y: auto; }
  .split .table { height: auto; }
  .tail { min-height: 0; overflow: auto; padding: 6px 8px; margin: 4px 14px 4px 0; border: 1px solid var(--line); background: var(--bg); }
  .click { cursor: pointer; }
  .click:hover td, .sel td { background: color-mix(in oklch, var(--accent) 12%, transparent); }
  .empty { padding: 10px 14px; color: var(--fg-3); }
  .table { font-size: 12.5px; }
  .table :global(th) { padding: 7px 8px; white-space: nowrap; }
  .table :global(td) { padding: 6px 8px; white-space: nowrap; }
  .table :global(th:first-child) { padding: 7px 16px; }
  .table :global(td:first-child) { padding: 6px 16px; font-weight: 400; }
  .table :global(td.empty) { white-space: normal; }
  td.muted { color: var(--fg-3); }
  td.soft { color: var(--fg-2); }
  td.unit { font-size: 11.5px; color: var(--fg-2); }
  td.act { padding: 1px 6px; text-align: right; }
  .res { display: flex; align-items: center; gap: 8px; }
  :global(.dot.run) { background: var(--info); box-shadow: 0 0 0 3px color-mix(in oklch, var(--info) 24%, transparent); }
  .tiles { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; padding: 10px 14px; }
  .tile { display: flex; flex-direction: column; gap: 4px; padding: 10px 12px; border: 1px solid var(--line); background: var(--panel-2); cursor: pointer; text-align: left; }
  .tile:hover { background: var(--panel-3); }
  .tn { display: flex; align-items: center; gap: 6px; font-weight: 500; }
  @media (max-width: 900px) { .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); } .split { grid-template-columns: minmax(0, 1fr); grid-template-rows: none; height: auto; } .tail { max-height: 240px; } }
</style>
