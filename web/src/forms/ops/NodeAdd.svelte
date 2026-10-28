<script>
  // Add a server to the list: hs sys node plan|start add <name> <host> [--kind peer|vps|edge] [--port N]. Changes nothing on the other server;
  // the key and the line its owner has to allow come next (Nodes page, drawer of the new node).
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone } = $props();

  let name = $state('');
  let host = $state('');
  let kind = $state('peer');
  let port = $state('');

  const args = () => {
    const n = name.trim();
    const h = host.trim();
    if (!n || !h) return null;
    const a = ['add', n, h, '--kind', kind];
    if (port.trim()) a.push('--port', port.trim());
    return a;
  };
  const kinds = [
    { id: 'peer', label: 'Another home server', hint: 'for example a relative\'s server; SSH user adminuser, port 22' },
    { id: 'edge', label: 'Edge node', hint: 'a public server of this repo (role edge); SSH user root, port 2222' },
    { id: 'vps', label: 'Proxyserver (old)', hint: 'the proxyserver of the old repo; SSH user root, port 2222' },
  ];
</script>

<CreateDialog title="Add a server" kicker="Add" area="node" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="nd-name">Name</label>
      <input id="nd-name" class="input" bind:value={name} placeholder="cousin" maxlength="31" autocomplete="off" spellcheck="false" />
      <div class="hint">Lower case letters, digits and dashes. It is the name in the address bar: /node/&lt;name&gt;.</div>
    </div>
    <div class="field">
      <label for="nd-host">Host name or address</label>
      <input id="nd-host" class="input" bind:value={host} placeholder="cousin-server.tail.ts.net" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="nd-kind">What it is</label>
      <select id="nd-kind" class="input" bind:value={kind}>
        {#each kinds as k (k.id)}<option value={k.id}>{k.label}</option>{/each}
      </select>
      <div class="hint">{kinds.find((k) => k.id === kind)?.hint}</div>
    </div>
    <div class="field">
      <label for="nd-port">SSH port <span class="opt">(optional)</span></label>
      <input id="nd-port" class="input" bind:value={port} placeholder={kind === 'peer' ? '22' : '2222'} inputmode="numeric" maxlength="5" autocomplete="off" />
    </div>
    <div class="hint">Nothing changes on the other server. Next you make the key and give its owner one line to allow.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--fg-3); margin-top: 3px; }
  .opt { color: var(--fg-3); font-weight: 400; }
</style>
