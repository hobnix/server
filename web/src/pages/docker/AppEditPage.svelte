<script>
  // The editor of one Docker app on its own page: docker-compose.yml left, the real .env text right (one column on a phone).
  // /instances/docker/app/<app> edits a web-managed app, /instances/docker/new starts one. The read `docker app` is never cached by the server
  // (it holds the .env text): this page reads it with get() and keeps the text only in its own state, never in a store or the browser's storage.
  // Test = the plan of `docker-app app-save` with the document {compose, env}, asked without a dialog: its `finding` lines are shown at their
  // lines in the panels (editor/findings.js), the ones without a place in a banner. Save (`app-write`) writes the two files only; Apply
  // (`app-save`) writes them and recreates the app. Both run the Test first and open the plan dialog only when it found no error.
  import { onMount } from 'svelte';
  import { get, plan } from '../../api.js';
  import { poll, rows, refresh } from '../../data.svelte.js';
  import { route, go } from '../../route.svelte.js';
  import { openPlan, jobRunning, tasks } from '../../ui.svelte.js';
  import { jobMatches } from '../../jobkey.js';
  import PageHeader from '../../shell/PageHeader.svelte';
  import Banner from '../../ui/Banner.svelte';
  import Button from '../../ui/Button.svelte';
  import { appOf, revOf, diskChanged } from './apps.js';
  import BindShare from '../../forms/docker/BindShare.svelte';
  import { ls } from '../../files/api.js';
  import { mountsOf } from '../../editor/volumes.js';
  import { lintCompose, lintEnv, lintVars, envNames, normalizeEol } from '../../editor/lint.js';
  import { mapFindings } from '../../editor/findings.js';
  import { convert } from '../../editor/dockerrun.js';
  import { takeHandoff } from '../../editor/wizard.js';

  const NEW = '/instances/docker/new';
  const PREFIX = '/instances/docker/app/';
  const template = 'services:\n  app:\n    image: nginx:alpine\n    ports:\n      - "8080:80"\n    env_file: .env\n    restart: unless-stopped\n';

  const isNew = $derived(route.path === NEW);
  const app = $derived(isNew ? '' : decodeURIComponent(route.path.slice(PREFIX.length)));
  let name = $state('');
  const target = $derived(isNew ? name.trim() : app);

  const appsPoll = poll('/api/sys/docker/apps', 30000);
  const ctPoll = poll('/api/sys/ct/list', 30000);
  const apps = $derived(rows(appsPoll).map(appOf).filter(Boolean));
  // for the live checks and the Bind share dialog: every container, what docker mounts, the shares, the user docker maps already
  const contPoll = poll('/api/sys/docker/containers', 30000);
  const storPoll = poll('/api/sys/ct/storage/docker', 15000);
  const sharesPoll = poll('/api/sys/shares/list', 30000);
  const remotePoll = poll('/api/sys/remote/list', 30000);
  const statusPoll = poll('/api/sys/docker/status', 15000);
  const containers = $derived(rows(contPoll).filter((r) => r.length >= 3).map((r) => ({ name: r[0], project: r[1], state: r[2] })));
  const mounts = $derived(mountsOf(rows(storPoll)));
  const shareNames = $derived(rows(sharesPoll).map((r) => r[0]).filter(Boolean));
  const peers = $derived.by(() => {
    const m = new Map();
    for (const r of rows(remotePoll)) if (r[0] === 'mount' && r[4] === 'mounted') m.set(r[1], [...(m.get(r[1]) ?? []), r[2]]);
    return [...m].map(([peer, shares]) => ({ peer, shares }));
  });
  const mapped = $derived.by(() => { const r = rows(statusPoll).find((x) => x[0] === 'mapped'); return r && r[1] !== '-' ? r[1] : ''; });
  // one fixed mapped user for the whole docker container: an app whose PUID:PGID differs would write as another user
  const idWarn = $derived.by(() => {
    if (!mapped) return '';
    const u = /^PUID=(\d+)\s*$/m.exec(env)?.[1];
    const g = /^PGID=(\d+)\s*$/m.exec(env)?.[1];
    return u && g && `${u}:${g}` !== mapped ? `PUID:PGID in .env is ${u}:${g}, but Docker maps ${mapped} for all shares. Files would be written as another user.` : '';
  });

  let loading = $state(true);
  let loadError = $state('');
  let rev = $state('new');
  let managed = $state('web');
  let envTooBig = $state(false);
  let compose = $state('');
  let env = $state('');
  let saved = $state({ compose: '', env: '' });
  let composeBox = $state();
  let envBox = $state();
  let editors = $state.raw(null);      // { compose, env } once cm.js is loaded (read by the Bind share button: must be reactive)
  let schema = null;

  const readOnly = $derived(!isNew && managed !== 'web');
  const dirty = $derived(compose !== saved.compose || env !== saved.env);
  const canApply = $derived(!loading && !loadError && !readOnly && !!target && /^[a-z0-9][a-z0-9_-]{0,40}$/.test(target));
  const applyArgs = $derived([target, 'app-save', '--rev', isNew ? 'new' : rev]);
  const saveArgs = $derived([target, 'app-write', '--rev', isNew ? 'new' : rev]);
  const applying = $derived(canApply && jobRunning('docker-app', applyArgs));
  const saving = $derived(canApply && jobRunning('docker-app', saveArgs));
  let testing = $state(false);          // the Test is being asked
  let banner = $state([]);              // findings without a place: [{ level, text }]
  let result = $state(null);            // { errors, warns } of the last Test, until the text changes
  let changedDisk = $state(false);      // the app changed on disk since it was read (the Test said so, or the poll of the revision)
  // the revision of the files on disk, read every 30 s while the page is open (a new app has none); no reload by itself
  const revPoll = poll(() => (isNew || !app || loading || loadError ? '' : `/api/sys/docker/rev/${encodeURIComponent(app)}`), 30000);
  let revFresh = $state(false);         // false from the start of a load until the fresh read of the revision returned: the poll may hold an older one
  const diskMoved = $derived(!isNew && revFresh && diskChanged(rev, revOf(revPoll.data)));

  // New app: a pasted `docker run` command becomes the compose text and the env text (the owner edits both before Save or Apply)
  let runOpen = $state(false);
  let runText = $state('');
  let runError = $state('');
  let runNotes = $state([]);
  function fromRun() {
    const r = convert(runText);
    runError = r.error || '';
    runNotes = r.notes;
    if (r.error) return;
    if (!name.trim()) name = r.name;
    compose = r.compose; env = r.env;
    editors?.compose.setText(compose);
    editors?.env.setText(env);
    runOpen = false;
    runText = '';
  }

  const live = () => ({
    schema, isNew,
    apps: apps.map((a) => ({ name: a.name, ports: a.ports })),
    ct: rows(ctPoll).map((r) => r[0]),
    containers, mounts, mapped,
  });

  async function load() {
    loading = true;
    loadError = '';
    changedDisk = false;
    revFresh = false;
    try {
      let handed = false;
      if (isNew) {
        rev = 'new'; managed = 'web'; envTooBig = false;
        // from the guided wizard: its text, once (in memory only, the .env may hold secrets); else the template
        const h = takeHandoff();
        if (h) { name = h.name; handed = true; }
        compose = h ? h.compose : template; env = h ? h.env : '';
      } else {
        const d = await get(`/api/sys/docker/app/${encodeURIComponent(app)}`);
        rev = d.rev; managed = d.managed; envTooBig = !!d.envTooBig;
        compose = normalizeEol(d.compose); env = normalizeEol(d.envText);
      }
      saved = handed ? { compose: '', env: '' } : { compose, env };   // handed-over text counts as not saved yet
      if (!isNew) await refresh([`/api/sys/docker/rev/${encodeURIComponent(app)}`]);   // the poll must not compare with the revision from before this load
      revFresh = true;
      if (editors) {
        editors.compose.setText(compose);
        editors.env.setText(env);
        editors.compose.setReadOnly(readOnly);
        editors.env.setReadOnly(readOnly || envTooBig);
      }
    } catch (e) {
      loadError = e.message || 'Could not load the app.';
    } finally {
      loading = false;
    }
  }

  // CodeMirror is loaded when this page opens (its own chunk: the main bundle stays small)
  onMount(() => {
    let gone = false;
    (async () => {
      await load();
      const [cm, spec] = await Promise.all([import('../../editor/cm.js'), import('../../editor/compose-spec.json')]);
      if (gone || !composeBox || !envBox) return;
      schema = spec.default;
      editors = {
        compose: cm.createEditor(composeBox, {
          doc: compose, lang: 'yaml', schema, readOnly,
          envNames: () => envNames(env),
          mounts: () => mounts,
          listDir: async (mount, rel) => (mount.share ? listShare(mount.share, `/${rel}`) : []),
          onChange: (t) => { compose = t; },
          lint: (text, obj) => [...lintCompose(obj, live(), target), ...lintVars(text, env)],
        }),
        env: cm.createEditor(envBox, {
          doc: env, lang: 'env', readOnly: readOnly || envTooBig,
          onChange: (t) => { env = t; editors?.compose.relint(); },
          lint: (text) => lintEnv(text),
        }),
      };
    })();
    return () => { gone = true; editors?.compose.destroy(); editors?.env.destroy(); editors = null; };
  });

  // the route changed to another app: read it
  let shown = '';
  $effect(() => {
    const key = isNew ? NEW : app;
    if (shown && shown !== key) load();
    shown = key;
  });

  // an edit makes the answer of the last Test stale
  $effect(() => {
    compose; env;
    result = null;
    banner = [];
  });

  // the job of Save or Apply ended: read the app again (new revision); a new app moves to its own address
  let wasApplying = false;
  $effect(() => {
    if (applying || saving) { wasApplying = true; return; }
    if (wasApplying) {
      wasApplying = false;
      if (isNew) go(PREFIX + encodeURIComponent(target)); else load();
    }
  });

  // Bind share: a mounted share adds its line at once; otherwise the plan of the mount runs first and the line is added when its job ends
  let binding = $state(false);
  let pending = $state(null);      // { args, line }
  const mountRunning = $derived(!!pending && jobRunning('docker', pending.args));
  let sawMount = false;
  $effect(() => {
    if (mountRunning) { sawMount = true; return; }
    if (sawMount && pending) {
      sawMount = false;
      const { args, line } = pending;
      pending = null;
      // the line only goes in when the mount worked: the newest task of this plan ended ok
      const t = tasks.list.find((x) => jobMatches(x.key, 'docker', args));
      if (t && t.state === 'ok') editors?.compose.insertVolume(line);
    }
  });
  async function listShare(share, path) {
    const r = await ls(`share:${share}`, path);
    return r.ok ? r.rows.filter((x) => x.type === 'd').map((x) => x.name) : [];
  }
  function bound(line) { binding = false; editors?.compose.insertVolume(line); }
  function mountFirst(m) { binding = false; pending = m; sawMount = false; openPlan('docker', m.args, `mount ${m.args[1]}`); }

  const document_ = () => (envTooBig ? { compose, set: {}, remove: [] } : { compose, env });

  // ask the plan with the document, show every finding at its place; -> the answer, or null when the call failed
  async function runTest(args) {
    testing = true;
    changedDisk = false;
    try {
      const r = await plan('docker-app', args, undefined, undefined, undefined, document_());
      const m = mapFindings(r.findings);
      editors?.compose.setFindings(m.compose);
      editors?.env.setFindings(m.env);
      const all = [...m.compose, ...m.env, ...m.banner];
      banner = m.banner;
      if (r.status !== 'ok' && !all.length && String(r.reason).includes('changed meanwhile')) changedDisk = true;
      else if (r.status !== 'ok' && !all.length) banner = [{ level: 'error', text: r.reason || 'The test could not be done.' }];
      result = { errors: all.filter((f) => f.level === 'error').length, warns: all.filter((f) => f.level !== 'error').length, ok: r.status === 'ok' };
      return r;
    } catch (e) {
      banner = [{ level: 'error', text: e.message || 'The test could not be done.' }];
      return null;
    } finally {
      testing = false;
    }
  }

  async function test() { await runTest(applyArgs); }      // the plain Test is the one of Apply: it also reports a closed vault

  // Save and Apply: the Test first; the plan dialog opens when it found no error, or when the refusal has no finding to show (its reason and fix)
  async function submit(args, title) {
    const r = await runTest(args);       // the Test of the action itself: Save never needs the registry vault
    if (!r || changedDisk) return;
    if (r.status === 'ok' || !r.findings?.length) openPlan('docker-app', args, `${title} ${target}`, { document: document_(), onReload: load });
  }
  const save = () => submit(saveArgs, 'save');
  const apply = () => submit(applyArgs, 'apply');

  const resultText = $derived(!result ? '' : result.errors ? `The test found ${result.errors} ${result.errors === 1 ? 'problem' : 'problems'}${result.warns ? ` and ${result.warns} ${result.warns === 1 ? 'warning' : 'warnings'}` : ''}.` : result.warns ? `The test passed with ${result.warns} ${result.warns === 1 ? 'warning' : 'warnings'}.` : 'The test found no problem.');
</script>

<svelte:window onbeforeunload={(e) => { if (dirty) { e.preventDefault(); e.returnValue = ''; } }} />

<PageHeader title={isNew ? 'New app' : app} crumb="Docker" sub={isNew ? 'Write a compose file and an env file, test it, then save or apply.' : 'Edit the compose file and the env file of this app, test it, then save or apply.'}>
  {#snippet actions()}
    {#if !readOnly}
      <Button icon="folder-simple-plus" busy={mountRunning} busyLabel="Mounting…" disabled={loading || !editors} tooltip="Add a share to a service as a volume" onclick={() => { binding = true; }}>Bind share</Button>
      <Button icon="list-checks" busy={testing} busyLabel="Testing…" disabled={!canApply || testing} tooltip={canApply ? 'Check both files without changing anything' : 'Name the app first'} onclick={test}>Test</Button>
      <Button icon="floppy-disk" busy={saving} busyLabel="Saving…" disabled={!canApply || testing || applying} tooltip={canApply ? 'Test, then write both files; the app keeps running as it is' : 'Name the app first'} onclick={save}>Save</Button>
      <Button variant="primary" icon="check-circle" busy={applying} busyLabel="Applying…" disabled={!canApply || testing || saving} tooltip={canApply ? 'Test, then save both files and recreate the app' : 'Name the app first'} onclick={apply}>Apply</Button>
    {/if}
  {/snippet}
</PageHeader>

{#if loadError}<Banner tone="bad">{loadError}</Banner>{/if}
{#if readOnly}<Banner tone="info">This app is not managed by the web interface (it is {managed}), so it can be read here but not changed.</Banner>{/if}
{#if envTooBig}<Banner tone="warn">The env file is over 64 KiB: edit it in a terminal. Apply keeps it as it is.</Banner>{/if}
{#if idWarn}<Banner tone="warn">{idWarn}</Banner>{/if}
{#if changedDisk || diskMoved}
  <Banner tone="warn">This app changed on disk since you opened it. Reload shows the new files; your edits here are lost.
    {#snippet action()}<Button size="sm" onclick={() => { load(); }}>Reload</Button>{/snippet}
  </Banner>
{/if}
{#each banner as b}<Banner tone={b.level === 'error' ? 'bad' : 'warn'}>{b.text}</Banner>{/each}
{#if result && !changedDisk && !diskMoved}<Banner tone={result.errors ? 'bad' : result.warns ? 'warn' : 'ok'}>{resultText}</Banner>{/if}
{#if dirty && !loading}<div class="dirty">Changed, not saved yet.</div>{/if}

{#if isNew}
  <div class="newrow">
    <label class="namef">Name
      <input class="input" bind:value={name} placeholder="my-app" autocapitalize="off" autocorrect="off" spellcheck="false" />
    </label>
    <Button icon="magic-wand" disabled={loading} tooltip="Answer a few questions instead; the text comes back here" onclick={() => go('/instances/docker/wizard')}>Guided</Button>
    <Button icon="terminal-window" disabled={loading || !editors} tooltip="Paste a docker run command and turn it into a compose file" onclick={() => { runOpen = !runOpen; }}>From docker run</Button>
  </div>
  {#if runOpen}
    <div class="runbox">
      <textarea class="input" rows="4" bind:value={runText} placeholder="docker run -d --name my-app -p 8080:80 -e TZ=Europe/Vienna nginx:alpine" spellcheck="false" autocapitalize="off" autocorrect="off"></textarea>
      <div class="runact">
        <Button variant="primary" disabled={!runText.trim()} onclick={fromRun}>Convert</Button>
        <span class="hint">This replaces the text in both panels. Secrets from -e go to the .env panel.</span>
      </div>
    </div>
  {/if}
  {#if runError}<Banner tone="bad">{runError}</Banner>{/if}
  {#each runNotes as n}<Banner tone="warn">{n}</Banner>{/each}
{/if}

{#if binding}
  <BindShare shares={shareNames} {peers} {mounts} {mapped} listDir={listShare} onsubmit={bound} onmount={mountFirst} onclose={() => { binding = false; }} />
{/if}

<div class="grid">
  <section class="panel">
    <div class="ph">docker-compose.yml</div>
    <div class="box" bind:this={composeBox}></div>
  </section>
  <section class="panel">
    <div class="ph">.env <span class="hint">values of PASS, TOKEN, SECRET and KEY names are hidden until you press show</span></div>
    <div class="box" bind:this={envBox}></div>
  </section>
</div>

<style>
  .grid { display: grid; grid-template-columns: 3fr 2fr; gap: 12px; margin-top: 12px; }
  .panel { display: flex; flex-direction: column; min-width: 0; border: 1px solid var(--line); background: var(--panel); }
  .ph { padding: 8px 12px; font: 12px var(--mono); color: var(--fg-2); border-bottom: 1px solid var(--line); }
  .hint { color: var(--fg-3); margin-left: 8px; }
  .box { height: 60vh; min-height: 60vh; }
  .box :global(.cm-editor) { height: 100%; }
  .dirty { font: 12px var(--mono); color: var(--warn); margin-top: 8px; }
  .newrow { display: flex; align-items: flex-end; gap: 12px; margin-top: 12px; }
  .runbox { margin-top: 8px; display: flex; flex-direction: column; gap: 8px; }
  .runbox textarea { font: 12px var(--mono); }
  .runact { display: flex; align-items: center; gap: 12px; }
  .namef { display: flex; flex-direction: column; gap: 4px; max-width: 320px; }
  @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
</style>
