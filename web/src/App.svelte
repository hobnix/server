<script>
  import { onMount } from 'svelte';
  import { session, logout, setAuthLostHandler } from './api.js';
  import { initLang } from './lang.svelte.js';
  import { clearPollCache } from './data.svelte.js';
  import { ui } from './ui.svelte.js';
  import Shell from './shell/Shell.svelte';
  import Login from './Login.svelte';
  import Terminal from './shell/Terminal.svelte';
  import Tooltip from './ui/Tooltip.svelte';

  let user = $state(null);
  let ready = $state(false);
  // a terminal popped out of the page: /?terminal=host|<instance>&title=...
  const pop = new URLSearchParams(location.search).get('terminal');
  const popTitle = new URLSearchParams(location.search).get('title') ?? '';

  setAuthLostHandler(() => { clearPollCache(); user = null; });

  onMount(async () => {
    try { user = await session(); } catch { user = null; }
    ui.features = user?.features ?? { terminal: false, vps: false };
    initLang(ui.features.language);
    ready = true;
  });

  async function signOut() {
    try { await logout(); } catch { /* the session is gone either way */ }
    clearPollCache();
    user = null;
  }
</script>

{#if !ready}
  <div style="flex:1"></div>
{:else if !user}
  <Login onsignedin={(s) => { ui.features = s?.features ?? { terminal: false, vps: false }; initLang(ui.features.language); user = s; }} />
{:else if pop && ui.features.terminal}
  <Terminal target={pop} title={popTitle} page />
{:else}
  <Shell {user} onsignout={signOut} />
{/if}

<Tooltip />
