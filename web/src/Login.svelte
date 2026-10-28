<script>
  import { tip } from './ui/tooltip.svelte.js';
  import { onMount } from 'svelte';
  import { hello, login } from './api.js';
  import { lang, setLang, t } from './lang.svelte.js';
  import { theme, toggleTheme } from './theme.svelte.js';
  import Halftone from './shell/Halftone.svelte';
  import Banner from './ui/Banner.svelte';
  import StatusDot from './ui/StatusDot.svelte';
  import Logo from './ui/Logo.svelte';

  let { onsignedin } = $props();

  // the page is served with the realm and the lock state in a <meta> tag, so the switch and the HOME\ prefix are there from the first paint
  function fromMeta() {
    try {
      const raw = document.querySelector('meta[name="hs-hello"]')?.getAttribute('content');
      return raw ? { facts: [], ...JSON.parse(raw) } : null;
    } catch { return null; }
  }
  const meta = fromMeta();
  let info = $state(meta);        // /api/hello: locked, domain {available, workgroup, realm} | null, local_user, facts
  let loadError = $state(false);
  let realm = $state(meta && !meta.domain?.available ? 'local' : 'domain');   // 'domain' | 'local'
  let user = $state('');
  let password = $state('');
  let show = $state(false);
  let busy = $state(false);
  let error = $state('');

  const domain = $derived(info?.domain ?? null);
  const domainOpen = $derived(!!domain?.available);
  const locked = $derived(!!info?.locked);

  async function load() {
    try {
      info = await hello();
      loadError = false;
      if (!info.domain?.available) realm = 'local';
    } catch (e) {
      loadError = true;
    }
  }
  onMount(() => {
    load();
    const timer = setInterval(load, 15000);     // the lock state and the status lines change by themselves
    return () => clearInterval(timer);
  });

  // the realm can flip under the form (storage unlocked, or locked again): never leave "domain" selected when it is closed
  $effect(() => { if (info && !domainOpen && realm === 'domain') realm = 'local'; });

  async function submit(e) {
    e.preventDefault();
    if (busy || !user || !password) return;
    busy = true;
    error = '';
    try {
      const s = await login(realm, user.trim(), password);
      password = '';
      onsignedin(s);
    } catch (err) {
      error = err.message;
      password = '';
      if (err.status === 409) load();
    } finally {
      busy = false;
    }
  }
</script>

<div class="login">
  <section class="brandp" aria-label="homeserver">
    <!-- halftone slot: the brand panel (the glow sits on the right edge, behind the text) -->
    <Halftone cell={6} focus={[1, 0.5]} reach={1.1} opacity={0.9} />
    <div class="brand rel"><Logo size={34} />hobnix</div>
    <div class="facts rel">
      {#each info?.facts ?? [] as f}
        <div class="fact"><StatusDot state={f.dot === 'ok' || f.dot === 'warn' || f.dot === 'bad' ? f.dot : 'off'} label={f.text} /></div>
      {:else}
        <div class="fact"><StatusDot state={loadError ? 'bad' : 'off'} label={loadError ? t({ en: 'Not reachable', de: 'Nicht erreichbar' }) : t({ en: 'Loading…', de: 'Lädt…' })} /></div>
      {/each}
    </div>
  </section>

  <section class="formp gridbg">
    <div class="topr">
      <div class="lang" role="group" aria-label="Language">
        <button use:tip={'Deutsch'} aria-pressed={lang.code === 'de'} lang="de" onclick={() => setLang('de')}>DE</button>
        <button use:tip={'English'} aria-pressed={lang.code === 'en'} lang="en" onclick={() => setLang('en')}>EN</button>
      </div>
      <button class="iconbtn" aria-label={theme.dark ? 'Light look' : 'Dark look'} use:tip={theme.dark ? 'Light look' : 'Dark look'} onclick={toggleTheme}>
        <i class="ph ph-{theme.dark ? 'sun' : 'moon'}" style="font-size:16px"></i>
      </button>
    </div>

    <div class="center">
      <div class="card xh">
        <span class="stripe" aria-hidden="true"></span>
        <div class="eyebrow">homeserver</div>
        <h1>{t({ en: 'Sign in', de: 'Anmelden' })}</h1>

        {#if domain}
          <div class="seg" role="group" aria-label={t({ en: 'Account type', de: 'Kontoart' })}>
            <button use:tip={t({ en: 'The administrator account of this server', de: 'Das Administrator-Konto dieses Servers' })} type="button" aria-pressed={realm === 'local'} onclick={() => (realm = 'local')}><i class="ph ph-shield-check"></i>{t({ en: 'Local admin', de: 'Lokaler Admin' })}</button>
            <button use:tip={!domainOpen ? t({ en: 'Samba accounts cannot sign in now (storage locked)', de: 'Samba-Konten können sich jetzt nicht anmelden (Speicher gesperrt)' }) : ''} type="button" aria-pressed={realm === 'domain'} disabled={!domainOpen} onclick={() => (realm = 'domain')}><i class="ph ph-user"></i>{t({ en: 'Samba user', de: 'Samba-Konto' })}</button>
          </div>
        {/if}

        {#if locked}
          <Banner tone="warn" icon="lock">{t({ en: 'Storage is locked. Samba accounts live on it, so only the local admin can sign in. Unlock from the Summary page after signing in.', de: 'Der Speicher ist gesperrt. Samba-Konten liegen darauf, daher kann sich nur der lokale Admin anmelden. Entsperren auf der Übersicht nach dem Anmelden.' })}</Banner>
        {/if}
        {#if loadError}
          <Banner tone="bad" icon="plugs">{t({ en: 'The server did not answer. Is it starting up?', de: 'Der Server antwortet nicht. Startet er gerade?' })}</Banner>
        {/if}
        {#if error}
          <Banner tone="bad">{error}</Banner>
        {/if}

        <form onsubmit={submit}>
          {#if realm === 'domain'}
            <div class="field"><label for="dom">{t({ en: 'Domain', de: 'Domäne' })}</label><div class="inp"><input id="dom" type="text" value={domain?.workgroup} readonly /></div></div>
          {/if}
          <div class="field"><label for="user">{t({ en: 'User name', de: 'Benutzername' })}</label>
            <div class="inp"><input id="user" autocomplete="username" autocapitalize="none" spellcheck="false" placeholder={realm === 'domain' ? 'anna' : (info?.local_user ?? 'adminuser')} bind:value={user} /></div></div>
          <div class="field"><label for="password">{t({ en: 'Password', de: 'Passwort' })}</label>
            <div class="inp"><input id="password" class="pw" type={show ? 'text' : 'password'} autocomplete="current-password" placeholder="••••••••••••" bind:value={password} />
              <button use:tip={show ? t({ en: 'Hide the password', de: 'Passwort verbergen' }) : t({ en: 'Show the password', de: 'Passwort anzeigen' })} type="button" class="eye" aria-label={show ? t({ en: 'Hide the password', de: 'Passwort verbergen' }) : t({ en: 'Show the password', de: 'Passwort anzeigen' })} onclick={() => (show = !show)}><i class="ph ph-{show ? 'eye-slash' : 'eye'}" style="font-size:17px"></i></button></div></div>
          <p class="hint">
            {#if realm === 'domain'}{t({ en: 'Use the account you use for the file shares. Only members of Domain Admins can sign in.', de: 'Das Konto, das du für die Freigaben nutzt. Nur Mitglieder von Domain Admins können sich anmelden.' })}
            {:else}{t({ en: 'The built-in administrator of this server. Works while storage is locked.', de: 'Der eingebaute Administrator dieses Servers. Geht auch bei gesperrtem Speicher.' })}{/if}
          </p>
          <button class="btn btn-primary" type="submit" disabled={busy || !user || !password}><i class="ph ph-sign-in"></i>{busy ? t({ en: 'Signing in…', de: 'Anmelden…' }) : t({ en: 'Sign in', de: 'Anmelden' })}</button>
        </form>
      </div>
    </div>

    <div class="foot"><span class="mono">homeserver</span><span aria-hidden="true">·</span><span>{t({ en: 'self-hosted home server', de: 'Server für zu Hause' })}</span></div>
  </section>
</div>

<style>
  .login { flex: 1; min-height: 0; overflow: auto; display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(380px, 1fr); background: var(--bg); color: var(--fg); font-size: 14px; line-height: 1.45; }
  .rel { position: relative; z-index: 1; }
  .brandp { position: relative; display: flex; flex-direction: column; justify-content: space-between; padding: 32px 40px; overflow: hidden; border-right: 1px solid var(--line); background-color: var(--panel);
    background-image: linear-gradient(var(--grid) 1px, transparent 1px), linear-gradient(90deg, var(--grid) 1px, transparent 1px); background-size: 28px 28px; background-position: -1px -1px; }
  .brand { display: flex; align-items: center; gap: 10px; font-weight: 600; font-size: 20px; letter-spacing: -0.02em; }
  .facts { display: flex; flex-direction: column; gap: 8px; max-width: 440px; padding: 14px 16px; border: 1px solid var(--line-2); background: color-mix(in oklch, var(--panel) 80%, transparent); backdrop-filter: blur(2px); }
  .fact { font-size: 13px; }
  .formp { position: relative; display: flex; flex-direction: column; padding: 24px 32px; }
  .topr { display: flex; justify-content: flex-end; align-items: center; gap: 8px; }
  .lang { display: flex; border: 1px solid var(--line-2); background: var(--panel); }
  .lang button { height: 30px; padding: 0 10px; border: 0; background: none; color: var(--fg-3); font: 500 12px var(--mono); }
  .lang button[aria-pressed='true'] { background: var(--panel-3); color: var(--fg); }
  .iconbtn { width: 32px; height: 30px; display: grid; place-items: center; border: 1px solid var(--line-2); background: var(--panel); color: var(--fg-2); padding: 0; }
  .iconbtn:hover { background: var(--panel-2); }
  .center { flex: 1; display: grid; place-items: center; padding: 24px 0; }
  .card { position: relative; width: min(404px, 100%); display: flex; flex-direction: column; gap: 14px; padding: 28px 28px 26px; border: 1px solid var(--line); background: var(--panel); box-shadow: var(--shadow); }
  .stripe { position: absolute; left: 0; right: 0; top: 0; height: 3px; background: linear-gradient(90deg, var(--h3), var(--h1), var(--h4)); }
  h1 { margin: 0; font-size: 26px; font-weight: 600; letter-spacing: -0.03em; }
  .seg { display: flex; border: 1px solid var(--line-2); overflow: hidden; }
  .seg button { flex: 1; height: 34px; display: flex; align-items: center; justify-content: center; gap: 7px; border: 0; background: var(--panel-2); color: var(--fg-2); font-weight: 500; }
  .seg button + button { border-left: 1px solid var(--line-2); }
  .seg button[aria-pressed='true'] { background: var(--panel-3); color: var(--fg); }
  .seg button:disabled { opacity: 0.45; cursor: not-allowed; }
  form { display: flex; flex-direction: column; gap: 14px; }
  .inp { position: relative; }
  .inp input { width: 100%; height: 38px; padding: 0 12px; border: 1px solid var(--line-2); background: var(--panel-2); color: var(--fg); font: inherit; }
  .inp input[readonly] { color: var(--fg-3); font-family: var(--mono); }
  .inp input:focus-visible { border-color: var(--accent); outline: none; }
  .pw { padding-right: 42px !important; }
  .eye { position: absolute; right: 2px; top: 2px; width: 34px; height: 34px; display: grid; place-items: center; border: 0; background: none; color: var(--fg-3); padding: 0; }
  .eye:hover { color: var(--fg); }
  .hint { margin: 0; color: var(--fg-3); font-size: 12.5px; }
  .btn-primary { height: 38px; }
  .foot { display: flex; gap: 8px; justify-content: center; color: var(--fg-3); font-size: 12px; }
  @media (max-width: 860px) {
    .login { grid-template-columns: minmax(0, 1fr); }
    .brandp { padding: 22px 20px; min-height: 150px; border-right: 0; border-bottom: 1px solid var(--line); }
    .facts { display: none; }
    .formp { padding: 18px 16px; }
  }
</style>
