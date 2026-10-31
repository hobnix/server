<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // How old is what this page shows, and a button to read it all again now. The age is the oldest of the page's first reads (readsfor.js) as the
  // server reported it (X-HS-Age: an answer it kept for a while is shown at once while a new one is read); the button asks for ?fresh=1, which
  // runs the scripts instead of answering from the cache or from what the collector kept. The Data page lists every read with its interval.
  // Only the local node's pages have reads of this kind; a remote node's page shows nothing here.
  import { route, go } from '../route.svelte.js';
  import { readsFor } from '../readsfor.js';
  import { ui } from '../ui.svelte.js';
  import { ageOf, refresh, sync } from '../data.svelte.js';

  let now = $state(Date.now());
  $effect(() => {
    const t = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(t);
  });

  const paths = $derived(route.node && route.node !== ui.host ? [] : readsFor(route.path, ui.features.extensions, ui.features.live));
  // the oldest answer on screen; null until the first one arrived
  const age = $derived.by(() => {
    now;
    const a = paths.map(ageOf).filter((x) => x !== null);
    return a.length ? Math.max(...a) : null;
  });

  const words = (s) => (s < 5 ? 'now' : s < 90 ? `${Math.round(s)} s` : s < 5400 ? `${Math.round(s / 60)} min` : `${Math.round(s / 3600)} h`);
  const tone = $derived(age === null ? '' : age > 600 ? 'bad' : age > 120 ? 'warn' : '');
</script>

{#if paths.length}
  <span class="fresh {tone}" use:tip={age === null ? 'Waiting for the first answer' : `The oldest data on this page is ${words(age)} old. The server keeps the slow reads up to date in the background.`}>
    <span class="age">
      <i class="ph ph-clock"></i><span class="lbl">{age === null ? '…' : words(age)}</span>
    </span>
    <button class="ib" disabled={sync.busy} aria-label="Read this page again now" use:tip={'Read this page again now, not from the kept copy'} onclick={() => refresh(paths)}>
      <i class="ph ph-arrow-clockwise" class:spin={sync.busy}></i>
    </button>
    <button class="ib hide-s" aria-label="Open the Data page" use:tip={'Every read, how old it is and how long it takes'} onclick={() => go('/monitoring/diagnostics')}>
      <i class="ph ph-gauge"></i>
    </button>
  </span>
{/if}

<style>
  .fresh { display: flex; align-items: center; gap: 2px; font: 12px var(--mono); white-space: nowrap; color: var(--fg-2); }
  .age { display: inline-flex; align-items: center; gap: 6px; padding: 0 8px; }
  .fresh.warn { color: var(--warn-ink); }
  .fresh.bad { color: var(--bad-ink); }
  .ib { width: 28px; height: 28px; display: grid; place-items: center; border: 1px solid transparent; border-radius: var(--r); background: none; color: inherit; padding: 0; }
  .ib:hover { background: var(--panel-2); border-color: var(--line); }
  .ib:disabled { opacity: 0.5; }
  .spin { animation: rot 0.9s linear infinite; }
  @keyframes rot { to { transform: rotate(360deg); } }
  @media (max-width: 900px) { .lbl, .hide-s { display: none; } }
  @media (max-width: 700px) { .age { display: none; } }
</style>
