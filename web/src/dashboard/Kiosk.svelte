<script>
  // The full-screen dashboard at /dashboard: no sign-in, no tree, no links into the app. A 403/404 shows the text of the server
  // (it names what to switch on). Theme: the toggle of the top bar (theme.svelte.js).
  import { onMount, onDestroy } from 'svelte';
  import { theme, toggleTheme } from '../theme.svelte.js';
  import EmptyState from '../ui/EmptyState.svelte';
  import Board from './Board.svelte';
  import { boardPoll } from './board.svelte.js';

  const board = boardPoll();
  const host = location.hostname;
  const hm = () => new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  let clock = $state(hm());
  let tick;
  onMount(() => { tick = setInterval(() => { clock = hm(); }, 15000); });
  onDestroy(() => { clearInterval(tick); board.stop?.(); });
</script>

<div class="kiosk">
  <header>
    <b class="host">{host}</b>
    <span class="sp"></span>
    <span class="clock">{clock}</span>
    <button class="ib" aria-label={theme.dark ? 'Switch to the light look' : 'Switch to the dark look'} onclick={toggleTheme}>
      <i class="ph ph-{theme.dark ? 'sun' : 'moon'}" style="font-size:16px"></i>
    </button>
  </header>
  <main>
    {#if !board.loaded}
      <div></div>
    {:else if board.status === 403 || board.status === 404}
      <EmptyState icon="lock-simple" title="The dashboard is not available" text={board.error} />
    {:else if !board.doc}
      <EmptyState icon="wifi-slash" title="The dashboard cannot be loaded" text={board.error} />
    {:else}
      <Board doc={board.doc} {host} />
    {/if}
  </main>
</div>

<style>
  .kiosk { flex: 1; display: flex; flex-direction: column; min-height: 0; overflow: auto; background: var(--bg); }
  header { display: flex; align-items: center; gap: 12px; padding: 8px 20px; border-bottom: 1px solid var(--line); background: var(--panel); }
  .sp { flex: 1; }
  .host { font: 500 13px var(--mono); }
  .clock { font: 500 14px var(--mono); color: var(--fg-2); }
  .ib { display: grid; place-items: center; width: 30px; height: 30px; border: 1px solid var(--line); border-radius: var(--r); background: transparent; color: var(--fg-2); cursor: pointer; }
  main { padding: 20px; }
</style>
