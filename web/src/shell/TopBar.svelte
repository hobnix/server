<script>
  // Top bar: logo, node switcher, search, data age with refresh, storage state, theme toggle, power/update actions, user.
  // host = this node's name; node = the node the page on screen belongs to (the buttons act on it, and only on this server);
  // nodes = [{ name, kind, local, dot }] for the switcher; onmenu opens the tree as a slide-over on a phone.
  let { host = 'homeserver', node = 'homeserver', nodes = [], pending = 0, locked = false, user = '', onsignout, onmenu = () => {}, menuOpen = false } = $props();

  import { openPlan, openCreate, ui } from '../ui.svelte.js';
  import { go } from '../route.svelte.js';
  import { theme, toggleTheme } from '../theme.svelte.js';
  import StatusDot from '../ui/StatusDot.svelte';
  import Logo from '../ui/Logo.svelte';
  import Terminal from './Terminal.svelte';
  import Search from './Search.svelte';
  import Fresh from './Fresh.svelte';

  // Update, Reboot and Shutdown open the plan dialog; Reboot and Shutdown are red there (the word is typed). They act on this server only.
  const here = $derived(node === host);
  const updTitle = $derived(!here ? 'Update acts on this server only' : locked ? 'The storage is locked: unlock it first, an update would refuse' : 'Show what an update would change, then pull the configuration and rebuild');
  const powTitle = $derived(!here ? 'Reboot and shutdown act on this server only' : 'Show what a reboot would do');

  let menu = $state('');       // '' | 'node' | 'power'
  function pick(action, title) { menu = ''; openPlan('system', [action], title); }
  const current = $derived(nodes.find((n) => n.name === node));
</script>

<svelte:window onclick={() => (menu = '')} onkeydown={(e) => e.key === 'Escape' && (menu = '')} />

<header class="topbar">
  <button class="ib menu" aria-label="Open the resource tree" aria-expanded={menuOpen} title="Resources" onclick={(e) => { e.stopPropagation(); onmenu(); }}>
    <i class="ph ph-list" style="font-size:18px"></i>
  </button>
  <a class="brand" href="/" onclick={(e) => { e.preventDefault(); go(`/node/${encodeURIComponent(host)}`); }} aria-label="Home">
    <Logo size={28} /><span class="bn">hobnix</span>
  </a>
  <span class="vr hide-s"></span>

  <div class="swwrap">
    <button class="sw" aria-haspopup="menu" aria-expanded={menu === 'node'} title="Switch server" onclick={(e) => { e.stopPropagation(); menu = menu === 'node' ? '' : 'node'; }}>
      <StatusDot bare state={current?.dot?.state ?? 'off'} label={current?.dot?.title ?? 'no data'} />
      <span class="sn">{node}</span><i class="ph ph-caret-down" style="font-size:11px;color:var(--fg-3)"></i>
    </button>
    {#if menu === 'node'}
      <div class="pop" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
        <div class="pht">Servers</div>
        {#each nodes as n (n.name)}
          <a href="/node/{encodeURIComponent(n.name)}" class:cur={n.name === node} role="menuitem" onclick={(e) => { e.preventDefault(); menu = ''; go(`/node/${encodeURIComponent(n.name)}`); }}>
            <StatusDot bare state={n.dot?.state ?? 'off'} label={n.dot?.title ?? 'no data'} />
            <span class="nm">{n.name}</span>
            <span class="chip">{n.local ? 'this server' : n.kind}</span>
          </a>
        {/each}
      </div>
    {/if}
  </div>

  <Search />
  <div class="grow"></div>
  <Fresh />
  <span class="storage" class:locked title={locked ? 'Storage locked' : 'Storage open'}>
    <i class="ph ph-{locked ? 'lock-simple' : 'lock-simple-open'}"></i><span class="lbl">{locked ? 'Storage locked' : 'Storage open'}</span>
  </span>
  <span class="vr hide-s"></span>
  <button class="ib" aria-label={theme.dark ? 'Switch to the light look' : 'Switch to the dark look'} title={theme.dark ? 'Light look' : 'Dark look'} onclick={toggleTheme}>
    <i class="ph ph-{theme.dark ? 'sun' : 'moon'}" style="font-size:16px"></i>
  </button>
  <button class="ib hide-s" disabled={!here || !ui.features.terminal} title={ui.features.terminal ? 'A shell on this server, like an SSH login as adminuser' : 'Switch on webTerminal in machine.toml'} aria-label="Terminal" onclick={() => openCreate(Terminal, { target: 'host', title: host })}><i class="ph ph-terminal-window" style="font-size:16px"></i></button>
  <button class="ib upd" disabled={!here || locked} title={updTitle} aria-label={pending > 0 ? `Update, ${pending} new` : 'Update'} onclick={() => openPlan('system', ['update'], 'Update')}>
    <i class="ph ph-arrow-circle-up" style="font-size:16px"></i>{#if here && pending > 0}<span class="count" title="{pending} new change{pending === 1 ? '' : 's'} upstream (as of the last fetch)">{pending}</span>{/if}
  </button>
  <span class="powwrap">
    <button class="ib" disabled={!here} title={powTitle} aria-label="Power" aria-haspopup="menu" aria-expanded={menu === 'power'} onclick={(e) => { e.stopPropagation(); menu = menu === 'power' ? '' : 'power'; }}><i class="ph ph-power" style="font-size:16px"></i></button>
    {#if menu === 'power'}
      <div class="pop right" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
        <button class="item" role="menuitem" onclick={() => pick('reboot', 'Reboot')}><i class="ph ph-arrow-clockwise"></i>Reboot</button>
        <button class="item bad" role="menuitem" onclick={() => pick('shutdown', 'Shut down')}><i class="ph ph-power"></i>Shut down</button>
      </div>
    {/if}
  </span>
  <button class="user" onclick={onsignout} title="Sign out" aria-label="Sign out">
    <span class="avatar">{(user || '?').slice(0, 1).toUpperCase()}</span><span class="lbl un">{user}</span><i class="ph ph-sign-out lbl" style="color:var(--fg-3)"></i>
  </button>
</header>

<style>
  .topbar { position: relative; z-index: 30; flex: none; height: 52px; display: flex; align-items: center; gap: 12px; padding: 0 14px; background: var(--panel); border-bottom: 1px solid var(--line-2); }
  .grow { flex: 1; }
  .brand { display: flex; align-items: center; gap: 9px; font-weight: 600; font-size: 16px; letter-spacing: -0.02em; text-decoration: none; color: var(--fg); }
  .vr { width: 1px; height: 22px; background: var(--line-2); }
  .swwrap, .powwrap { position: relative; }
  .sw { height: 34px; display: flex; align-items: center; gap: 8px; padding: 0 10px; border: 1px solid var(--line-2); border-radius: var(--r); background: var(--panel-2); color: var(--fg); }
  .sw:hover { background: var(--panel-3); }
  .sn { font-weight: 500; max-width: 160px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .pop { position: absolute; top: calc(100% + 6px); left: 0; width: 310px; z-index: 40; background: var(--panel); border: 1px solid var(--line-2); border-radius: var(--r); box-shadow: var(--shadow); padding: 6px; display: flex; flex-direction: column; }
  .pop.right { left: auto; right: 0; width: 180px; }
  .pht { padding: 8px 10px 6px; font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-3); }
  .pop a { display: flex; align-items: center; gap: 10px; padding: 8px 10px; text-decoration: none; color: var(--fg); }
  .pop a:hover { background: var(--panel-2); }
  .pop a.cur { background: color-mix(in oklch, var(--accent) 16%, transparent); }
  .nm { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
  .chip { font: 500 10.5px var(--mono); text-transform: uppercase; letter-spacing: 0.06em; padding: 1px 6px; border: 1px solid var(--line-2); color: var(--fg-3); white-space: nowrap; }
  .item { display: flex; align-items: center; gap: 8px; padding: 8px 10px; border: 0; background: none; color: var(--fg); text-align: left; }
  .item:hover { background: var(--panel-2); }
  .item.bad { color: var(--bad-ink); }
  .ib { position: relative; width: 34px; height: 34px; display: grid; place-items: center; border: 1px solid transparent; border-radius: var(--r); background: transparent; color: var(--fg-2); padding: 0; flex: none; }
  .ib:hover:not(:disabled) { background: var(--panel-2); border-color: var(--line); color: var(--fg); }
  .ib:disabled { opacity: 0.4; cursor: not-allowed; }
  .menu { display: none; margin-left: -6px; }
  .count { position: absolute; top: 1px; right: 0; min-width: 15px; height: 15px; padding: 0 3px; font: 600 10px var(--mono); background: var(--accent); color: var(--on-accent); display: grid; place-items: center; }
  .storage { display: flex; align-items: center; gap: 6px; font-size: 12.5px; white-space: nowrap; color: var(--fg-3); }
  .storage.locked { color: var(--warn-ink); }
  .user { display: flex; align-items: center; gap: 8px; padding: 0 0 0 8px; margin-left: 2px; height: 34px; border: 0; border-left: 1px solid var(--line); background: none; color: var(--fg); }
  .avatar { width: 28px; height: 28px; border-radius: 50%; display: grid; place-items: center; font-weight: 600; font-size: 12px; color: var(--on-accent); background: linear-gradient(135deg, var(--h3), var(--h1) 60%, var(--h4)); }
  @media (max-width: 1000px) { .sn { max-width: 90px; } }
  @media (max-width: 860px) { .menu { display: grid; } .hide-s { display: none; } .topbar { gap: 8px; padding: 0 10px; } .bn { display: none; } }
  /* narrow: icons only, so the bar never overflows at 400 px */
  @media (max-width: 700px) { .lbl { display: none; } .user { padding-left: 4px; border-left: 0; } .pop { width: min(310px, 90vw); } }
  @media (max-width: 520px) { .sn { display: none; } .sw { padding: 0 8px; } .upd, .storage { display: none; } }
</style>
