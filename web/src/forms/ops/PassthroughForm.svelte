<script>
  // Forward a domain: hs sys ext passthrough plan|start <domain> add --address <a> [--https-port N] [--http-port N | --no-http] [--proxy-protocol]
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import Switch from '../../ui/Switch.svelte';

  let { onclose, ondone } = $props();

  let domain = $state('');
  let address = $state('');
  let httpsPort = $state('443');
  let httpPort = $state('80');
  let forwardHttp = $state(true);
  let proxy = $state(false);

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
    return a;
  };
</script>

<CreateDialog title="Forward a domain" kicker="Add" area="ext/passthrough" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="pt-domain">Domain</label>
      <input id="pt-domain" class="input" bind:value={domain} placeholder="example.com" maxlength="64" autocomplete="off" spellcheck="false" />
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
    <div class="field"><Switch bind:checked={forwardHttp} label="Forward HTTP (port 80)" /></div>
    <div class="field"><Switch bind:checked={proxy} label="Send PROXY protocol v2 on HTTPS" /></div>
    <div class="hint">The domain and all its subdomains go to this address. The target answers TLS itself; this server holds no certificate.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
