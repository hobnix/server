<script>
  // The editor of one Docker app on its own page: docker-compose.yml left, the real .env text right (one column on a phone).
  // /instances/docker/app/<app> edits a web-managed app, /instances/docker/new starts one. The read `docker app` is never cached by the server
  // (it holds the .env text): this page reads it with get() and keeps the text only in its own state, never in a store or the browser's storage.
  // Apply = a plan for `docker-app app-save` with the document {compose, env}; the plan dialog saves and recreates the app.
  import { onMount } from 'svelte';
  import { get } from '../../api.js';
  import { poll, rows } from '../../data.svelte.js';
  import { route, go } from '../../route.svelte.js';
  import { openPlan, jobRunning } from '../../ui.svelte.js';
  import PageHeader from '../../shell/PageHeader.svelte';
  import Banner from '../../ui/Banner.svelte';
  import Button from '../../ui/Button.svelte';
  import { appOf } from './apps.js';
  import { lintCompose, lintEnv, lintVars, envNames, normalizeEol } from '../../editor/lint.js';

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
  let editors = null;      // { compose, env } once cm.js is loaded
  let schema = null;

  const readOnly = $derived(!isNew && managed !== 'web');
  const dirty = $derived(compose !== saved.compose || env !== saved.env);
  const canApply = $derived(!loading && !loadError && !readOnly && !!target && /^[a-z0-9][a-z0-9_-]{0,40}$/.test(target));
  const applyArgs = $derived([target, 'app-save', '--rev', isNew ? 'new' : rev]);
  const applying = $derived(canApply && jobRunning('docker-app', applyArgs));

  const live = () => ({
    schema, isNew,
    apps: apps.map((a) => ({ name: a.name, ports: a.ports })),
    ct: rows(ctPoll).map((r) => r[0]),
  });

  async function load() {
    loading = true;
    loadError = '';
    try {
      if (isNew) {
        rev = 'new'; managed = 'web'; envTooBig = false;
        compose = template; env = '';
      } else {
        const d = await get(`/api/sys/docker/app/${encodeURIComponent(app)}`);
        rev = d.rev; managed = d.managed; envTooBig = !!d.envTooBig;
        compose = normalizeEol(d.compose); env = normalizeEol(d.envText);
      }
      saved = { compose, env };
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

  // the job of Apply ended: read the app again (new revision); a new app moves to its own address
  let wasApplying = false;
  $effect(() => {
    if (applying) { wasApplying = true; return; }
    if (wasApplying) {
      wasApplying = false;
      if (isNew) go(PREFIX + encodeURIComponent(target)); else load();
    }
  });

  function apply() {
    const document = envTooBig ? { compose, set: {}, remove: [] } : { compose, env };
    openPlan('docker-app', applyArgs, `apply ${target}`, { document, onReload: load });
  }
</script>

<svelte:window onbeforeunload={(e) => { if (dirty) { e.preventDefault(); e.returnValue = ''; } }} />

<PageHeader title={isNew ? 'New app' : app} crumb="Docker" sub={isNew ? 'Write a compose file and an env file, then apply.' : 'Edit the compose file and the env file of this app, then apply.'}>
  {#snippet actions()}
    {#if !readOnly}
      <Button variant="primary" icon="check-circle" busy={applying} busyLabel="Applying…" disabled={!canApply} tooltip={canApply ? 'Save both files and recreate the app' : 'Name the app first'} onclick={apply}>Apply</Button>
    {/if}
  {/snippet}
</PageHeader>

{#if loadError}<Banner tone="bad">{loadError}</Banner>{/if}
{#if readOnly}<Banner tone="info">This app is not managed by the web interface (it is {managed}), so it can be read here but not changed.</Banner>{/if}
{#if envTooBig}<Banner tone="warn">The env file is over 64 KiB: edit it in a terminal. Apply keeps it as it is.</Banner>{/if}
{#if dirty && !loading}<div class="dirty">Changed, not applied yet.</div>{/if}

{#if isNew}
  <label class="namef">Name
    <input class="input" bind:value={name} placeholder="my-app" autocapitalize="off" autocorrect="off" spellcheck="false" />
  </label>
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
  .namef { display: flex; flex-direction: column; gap: 4px; margin-top: 12px; max-width: 320px; }
  @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
</style>
