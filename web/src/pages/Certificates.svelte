<script>
  // The certificate of the domain controller (LDAPS) and the small CA of this setup that signs it: hs sys dc state / plan / start.
  import { poll, rows } from '../data.svelte.js';
  import { openPlan, ui } from '../ui.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import Banner from '../ui/Banner.svelte';

  const st = poll('/api/sys/dc/state', 30000);
  // key, value rows: ca, ca_until, dc, cert (ok|unreadable|none), subject, names, valid_until, days_left, checked
  const s = $derived(Object.fromEntries(rows(st).map((r) => [r[0], r[1] ?? ''])));
  const hasCa = $derived(s.ca === 'yes');
  const days = $derived(s.days_left !== undefined && s.days_left !== '' && !isNaN(s.days_left) ? Number(s.days_left) : null);
  const soon = $derived(days !== null && days < 60);
  const certOk = $derived(s.cert === 'ok');
</script>

<div class="page">
  <PageHeader title="Certificates" crumb="Identity" sub="LDAPS of the domain controller, signed by a small CA of this setup." />

  {#if st.loaded && st.error}
    <Banner tone="warn">The certificates could not be read. This server needs a domain (the recipe <code>domain</code>) and the controller must be running.</Banner>
  {/if}

  <div class="card" style="padding:14px 16px;gap:8px">
    <div class="row"><span class="h">The CA</span><div class="grow"></div>
      {#if st.loaded && !hasCa}<button class="btn btn-primary" onclick={() => openPlan('dc', ['ca'], 'Make the CA')}><i class="ph ph-certificate"></i>Make the CA…</button>{/if}
    </div>
    {#if hasCa}
      <div class="kv"><span>State</span><span><span class="dot ok"></span> exists, valid until {s.ca_until}</span></div>
      <div class="muted">It vouches only for names inside the domain. Its key is in the vault. The certificate to trust on the clients is <code>/var/lib/hs/dc-ca.pem</code>.</div>
    {:else if st.loaded}
      <div class="muted">No CA yet. Make it once, on the server that keeps it: it then signs the certificate of every controller.</div>
    {:else}
      <div class="muted">Loading…</div>
    {/if}
  </div>

  <div class="card" style="padding:14px 16px;gap:8px">
    <div class="row"><span class="h">Domain controller {s.dc && s.dc !== '-' ? s.dc : ''}</span><div class="grow"></div>
      <button class="btn btn-secondary" disabled={!hasCa || !s.dc || s.cert === 'none'} title={hasCa ? 'New key and certificate, installed, Samba restarts (shows the plan first)' : 'Make the CA first'}
        onclick={() => openPlan('dc', ['renew', '--dc', s.dc], 'Renew the certificate of ' + s.dc)}><i class="ph ph-arrows-clockwise"></i>Renew certificate…</button>
    </div>
    {#if certOk}
      <div class="kv"><span>Subject</span><span>{s.subject}</span></div>
      <div class="kv"><span>Names</span><span>{s.names}</span></div>
      <div class="kv"><span>Valid until</span><span>{s.valid_until}{#if days !== null} <span class="tag {soon ? 'tag-accent-2' : 'tag-neutral'}" style="padding:1px 7px">{days < 0 ? `${-days} days ago` : `${days} days left`}</span>{/if}</span></div>
      <div class="kv"><span>Signed by</span><span><span class="dot {s.checked === 'yes' ? 'ok' : 'warn'}"></span> {s.checked === 'yes' ? 'the CA of this setup' : 'not this CA (the self-signed certificate of Samba, valid only for the controller’s own name)'}</span></div>
    {:else if s.cert === 'none'}
      <div class="muted">There is no domain controller on this server.</div>
    {:else if s.cert === 'unreadable'}
      <div class="muted">The certificate of the controller could not be read (is it running?).</div>
    {:else if st.loaded}
      <div class="muted">Nothing to show.</div>
    {/if}
    <div class="muted">A controller on another server (a second one at the cousin's) is renewed in the terminal there: <code>hs dc cert request</code>, <code>sign</code> on the CA server, then <code>install</code>. The request travels between the two servers, so it stays out of the browser. Expiry dates are also tracked by <code>hs expiry</code>.</div>
  </div>
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .row { display: flex; align-items: center; gap: 10px; }
  .grow { flex: 1; }
  .h { font-size: 14px; font-weight: 500; }
  .btn { font-size: 13px; }
  .kv { display: flex; gap: 12px; font-size: 13px; }
  .kv > span:first-child { flex: 0 0 90px; color: var(--fg-3); }
  .kv > span:last-child { min-width: 0; overflow-wrap: anywhere; }
  .muted { font-size: 12px; color: var(--fg-3); }
</style>
