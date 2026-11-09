<script>
  // The package builder, first slice (ADR 0020, issue #268): a form for the manifest of a new package and the server's verdict on it, live.
  // The form makes a package.toml text (builder.js); the page sends it to `hs sys pkg plan check-draft` (the checks of `hs pkg validate`) and shows
  // the findings. Nothing is saved or written: drafts, the code editor and the pull request / archive step are later steps of the ADR.
  import { plan } from '../api.js';
  import { ui } from '../ui.svelte.js';
  import { tr } from '../i18n.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import Banner from '../ui/Banner.svelte';
  import Button from '../ui/Button.svelte';
  import { blank, manifestText, findingsOf, fieldOf } from './builder.js';

  let f = $state(blank());
  const text = $derived(manifestText(f));
  let found = $state([]);
  let state = $state('idle');               // idle | checking | valid | invalid | error
  let failure = $state('');
  let timer;
  let ctl;

  const check = async (t) => {
    ctl?.abort();
    ctl = new AbortController();
    state = 'checking';
    try {
      const r = await plan('pkg', ['check-draft'], undefined, undefined, ctl.signal, { manifest: t });
      found = findingsOf(r.findings);
      failure = '';
      state = r.status === 'ok' ? 'valid' : r.findings?.length ? 'invalid' : 'error';
      if (state === 'error') failure = r.reason || 'The draft could not be checked.';
    } catch (e) {
      if (e.name === 'AbortError') return;
      state = 'error';
      failure = e.message;
    }
  };
  // live: ask again 400 ms after the last keystroke
  $effect(() => {
    const t = text;
    clearTimeout(timer);
    timer = setTimeout(() => check(t), 400);
    return () => clearTimeout(timer);
  });

  const errors = $derived(found.filter((x) => x.level === 'error'));
  const forField = (name) => errors.filter((x) => fieldOf(x.where) === name);
  const copy = () => navigator.clipboard?.writeText(text).catch(() => {});
</script>

<PageHeader title="Package builder" crumb={ui.host} sub="Write the manifest of a new app or extension; the server checks it as you type. Nothing is saved yet." />

<div class="grid">
  <form class="card" onsubmit={(e) => e.preventDefault()}>
    <label>{tr('Kind')}
      <select bind:value={f.kind}>
        <option value="recipe">{tr('App (recipe)')}</option>
        <option value="extension">{tr('Extension')}</option>
      </select>
    </label>
    {#each [['name', 'Name', 'my-app'], ['title', 'Title', 'What it is, in a few words'], ['version', 'Version', '0.1.0'], ['requires', 'Needs core', '>=1']] as [k, label, ph]}
      <label>{tr(label)}
        <input bind:value={f[k]} placeholder={ph} class:bad={forField(k).length} autocomplete="off" spellcheck="false" />
        {#each forField(k) as x}<span class="why">{x.text}</span>{/each}
      </label>
    {/each}
    <label>{tr('For')}
      <select bind:value={f.audience}>
        <option value="generic">{tr('Everyone (generic)')}</option>
        <option value="personal">{tr('One person (personal)')}</option>
      </select>
    </label>
    {#if f.kind === 'recipe'}
      <label>{tr('Script')}
        <input bind:value={f.script} class:bad={forField('script').length} autocomplete="off" spellcheck="false" />
        {#each forField('script') as x}<span class="why">{x.text}</span>{/each}
      </label>
    {/if}
    <label>{tr('Permissions')}
      <textarea rows="3" bind:value={f.permissions} placeholder="web.read&#10;net:lan" spellcheck="false"></textarea>
      <span class="hint">{tr('One per line, for example web.read or net:lan. Declared, not enforced (ADR 0014).')}</span>
      {#each forField('permissions') as x}<span class="why">{x.text}</span>{/each}
    </label>
  </form>

  <div class="side">
    <div class="verdict" aria-live="polite">
      {#if state === 'checking' && !found.length}<span>{tr('Checking…')}</span>
      {:else if state === 'valid'}<Banner tone="ok">{tr('The manifest passes the checks.')}</Banner>
      {:else if state === 'invalid'}<Banner tone="bad">{errors.length} {tr(errors.length === 1 ? 'problem' : 'problems')}</Banner>
      {:else if state === 'error'}<Banner tone="warn">{failure}</Banner>{/if}
      {#each found.filter((x) => x.level !== 'error') as x}<Banner tone="info">{x.text}</Banner>{/each}
      {#each errors.filter((x) => !fieldOf(x.where)) as x}<Banner tone="bad">{x.text}</Banner>{/each}
    </div>
    <div class="card">
      <div class="head"><b>package.toml</b><Button size="sm" onclick={copy}>Copy</Button></div>
      <pre>{text}</pre>
    </div>
  </div>
</div>

<style>
  .grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 16px; align-items: start; }
  @media (max-width: 800px) { .grid { grid-template-columns: 1fr; } }
  .card { display: flex; flex-direction: column; gap: 12px; padding: 16px; border: 1px solid var(--line); border-radius: var(--r); background: var(--panel); }
  .side { display: flex; flex-direction: column; gap: 12px; }
  .verdict { display: flex; flex-direction: column; gap: 8px; }
  label { display: flex; flex-direction: column; gap: 4px; font-size: 13px; }
  input, select, textarea { padding: 7px 9px; border: 1px solid var(--line); border-radius: var(--r); background: var(--bg); color: inherit; font: inherit; }
  input.bad { border-color: var(--bad); }
  .why { color: var(--bad); }
  .hint { color: var(--muted, var(--dim)); }
  .head { display: flex; justify-content: space-between; align-items: center; }
  pre { margin: 0; white-space: pre-wrap; word-break: break-word; font-family: var(--mono, monospace); font-size: 13px; }
</style>
