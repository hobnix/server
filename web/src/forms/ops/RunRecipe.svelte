<script>
  // Run an app recipe as a job (hs sys recipes plan|start <recipe> run [--name <container>] [--set KEY=value]...).
  // A recipe that asks things declares them (`# ask:` in its header, `hs sys recipes asks <recipe>`): the form shows one field per question,
  // text and choices go as --set, the one secret goes on standard input (never in an argument or a log). Everything else a recipe asks
  // (memory, port, share ...) takes the answer stored last time or its default.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { get } from '../../api.js';

  let { recipe, onclose, ondone } = $props();

  let own = $state('');
  let loaded = $state(false);
  let loadError = $state('');
  let asks = $state([]);      // { key, label, kind, def, pattern, when }
  let input = $state('none');
  let values = $state({});    // key -> text/choice answers
  let secret = $state('');

  $effect(() => {
    get(`/api/sys/recipes/asks/${encodeURIComponent(recipe)}`)
      .then((r) => {
        const rows = r?.rows ?? [];
        const dash = (v) => (v === '-' || v === undefined ? '' : v);
        asks = rows.filter((x) => x[0] !== 'input').map((x) => ({ key: x[0], label: x[1], kind: x[2], def: dash(x[3]), pattern: dash(x[4]), when: dash(x[5]) }));
        input = rows.find((x) => x[0] === 'input')?.[1] ?? 'none';
        const v = {};
        for (const a of asks) if (a.kind !== 'secret') v[a.key] = a.def;
        values = v;
        loaded = true;
      })
      .catch((e) => { loadError = e.message; loaded = true; });
  });

  // a question counts while its `when` (KEY=value) holds
  const active = (a) => !a.when || (values[a.when.split('=')[0]] ?? '') === a.when.slice(a.when.indexOf('=') + 1);
  const shown = $derived(asks.filter(active));
  const secretAsk = $derived(shown.find((a) => a.kind === 'secret'));
  const choices = (a) => a.kind.slice('choice:'.length).split(',');
  // text without a pattern may stay empty; everything else is needed before the plan is asked
  const missing = $derived(shown.some((a) => (a.kind === 'secret' ? !secret : !(values[a.key] ?? '') && (a.kind !== 'text' || a.pattern))));

  const args = () => {
    if (!loaded || loadError || input === 'terminal' || missing) return null;
    const n = own.trim();
    const a = [recipe, 'run'];
    if (n) a.push('--name', n);
    for (const q of shown) if (q.kind !== 'secret' && (values[q.key] ?? '') !== '') a.push('--set', `${q.key}=${values[q.key]}`);
    return a;
  };
  const stdin = () => (secretAsk && secret ? secret : undefined);
</script>

<CreateDialog title="Run {recipe}" kicker="Apps" area="recipes" {args} {stdin} {onclose} {ondone}>
  {#snippet form()}
    {#if loadError}
      <div class="hint">The questions of this recipe could not be read: {loadError}</div>
    {:else if input === 'terminal'}
      <div class="hint">This recipe needs a person at a terminal (a password is typed into the setup). Run <code>hs recipe {recipe}</code> on the server.</div>
    {:else}
      {#each shown as q (q.key)}
        <div class="field">
          <label for="rr-{q.key}">{q.label}</label>
          {#if q.kind === 'secret'}
            <input id="rr-{q.key}" class="input" type="password" bind:value={secret} autocomplete="new-password" spellcheck="false" />
          {:else if q.kind.startsWith('choice:')}
            <select id="rr-{q.key}" class="input" bind:value={values[q.key]}>
              {#each choices(q) as c}<option value={c}>{c}</option>{/each}
            </select>
          {:else}
            <input id="rr-{q.key}" class="input" bind:value={values[q.key]} autocomplete="off" spellcheck="false" />
          {/if}
        </div>
      {/each}
      <div class="field">
        <label for="rr-name">Container name (optional)</label>
        <input id="rr-name" class="input" bind:value={own} placeholder={recipe} maxlength="41" autocomplete="off" spellcheck="false" />
      </div>
      <div class="hint">
        Leave the name empty for the usual container. A name of your own runs the recipe a second time, for example a second Jellyfin.
        {#if secretAsk}The secret goes only into the container, never into the log.{/if}
        Preferences the recipe does not ask here (memory, port, share ...) use the answers stored last time, or the defaults; to choose them yourself run <code>hs recipe {recipe}</code> in the terminal.
      </div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
