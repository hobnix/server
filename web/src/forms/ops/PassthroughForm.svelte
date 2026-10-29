<script>
  // Forward a domain: hs sys ext passthrough plan|start <domain> add --address <a> [--https-port N] [--http-port N | --no-http] [--proxy-protocol] [--container-ok]
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import Switch from '../../ui/Switch.svelte';

  // `row` (from the Edit row action): the forwarded domain to change. `add` on a forwarded domain replaces its target, the plan says so.
  let { onclose, ondone, row = null } = $props();

  const dash = (v) => (v && v !== '-' ? v : '');
  let domain = $state(row?.domain ?? '');
  let address = $state(dash(row?.address));
  let httpsPort = $state(dash(row?.https) || '443');
  let httpPort = $state(dash(row?.http) || '80');
  let forwardHttp = $state(row ? !!dash(row.http) : true);
  let proxy = $state(row?.proxy === 'on');
  let containerOk = $state(false);   // never pre-ticked: shown only once the plan refuses a container of this server

  // the plan answers "needs address" while it is empty and refuses a domain or address the script does not accept
  const args = () => {
    const d = domain.trim();
    if (!d) return null;
    const a = [d, 'add'];
    if (address.trim()) a.push('--address', address.trim());
    if (httpsPort.trim() && httpsPort.trim() !== '443') a.push('--https-port', httpsPort.trim());
    if (!forwardHttp) a.push('--no-http');
    else if (httpPort.trim() && httpPort.trim() !== '80') a.push('--http-port', httpPort.trim());
    if (proxy) a.push('--proxy-protocol');
    if (containerOk) a.push('--container-ok');
    return a;
  };
</script>

<CreateDialog title={row ? 'Change ' + row.domain : 'Forward a domain'} kicker={row ? 'Edit' : 'Add'} area="ext/passthrough" {args} {onclose} {ondone}>
  {#snippet form(plan)}
    <div class="field">
      <label for="pt-domain">Domain</label>
      <input id="pt-domain" class="input" bind:value={domain} readonly={!!row} placeholder="example.com" maxlength="64" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="pt-address">Address of the reverse proxy on the LAN</label>
      <input id="pt-address" class="input" bind:value={address} placeholder="192.168.1.20" maxlength="39" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="pt-https">HTTPS port of the target</label>
      <input id="pt-https" class="input" bind:value={httpsPort} placeholder="443" maxlength="5" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="pt-http">HTTP port of the target</label>
      <input id="pt-http" class="input" bind:value={httpPort} placeholder="80" maxlength="5" disabled={!forwardHttp} autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <span class="sw-row"><Switch bind:checked={forwardHttp} label="Forward HTTP (port 80)" /><span>Forward plain HTTP too (port 80, the Host name is kept)</span></span>
    </div>
    <div class="field">
      <span class="sw-row"><Switch bind:checked={proxy} label="Send PROXY protocol v2 on HTTPS" /><span>Send the PROXY protocol on HTTPS, so the target sees the real visitor address. Switch it on only if the target expects it.</span></span>
    </div>
    {#if containerOk || (plan?.status === 'refused' && plan.reason?.includes('--container-ok'))}
      <div class="field">
        <span class="sw-row"><Switch bind:checked={containerOk} label="Yes, this is a container on this server: send the whole domain to it." /><span>Yes, this is a container on this server: send the whole domain to it.</span></span>
        <div class="hint">The domain and all its subdomains then reach that container from the internet. You confirm by typing the domain in the plan.</div>
      </div>
    {/if}
    <div class="hint">The domain and all its subdomains go to this address. The target answers TLS itself; this server holds no certificate.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--color-neutral-500); }
  .sw-row { display: inline-flex; align-items: flex-start; gap: 10px; font-size: 13px; }
</style>
