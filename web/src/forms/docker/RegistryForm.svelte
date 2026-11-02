<script>
  // Add a registry login: hs sys docker-registry plan|start add <host> --user <user>. The token is the one line on standard input: it never goes into
  // an argument or a log, and it is not shown again.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone } = $props();

  let host = $state('ghcr.io');
  let user = $state('');
  let token = $state('');

  const HOST_RE = /^[a-z0-9.-]{1,100}(:[0-9]{1,5})?$/;
  const args = () => {
    const h = host.trim();
    const u = user.trim();
    if (!HOST_RE.test(h) || !u) return null;
    return ['add', h, '--user', u];
  };
  const stdin = () => token.trim() || undefined;
</script>

<CreateDialog title="New registry login" kicker="Registries" area="docker-registry" {args} {stdin} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="rg-host">Registry</label>
      <input id="rg-host" class="input" bind:value={host} placeholder="ghcr.io" maxlength="106" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="rg-user">User</label>
      <input id="rg-user" class="input" bind:value={user} placeholder="your-github-name" maxlength="100" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="rg-token">Token</label>
      <input id="rg-token" class="input" type="password" bind:value={token} autocomplete="new-password" spellcheck="false" />
    </div>
    <div class="hint">For GitHub use a classic token with <code>read:packages</code> only. The token is tested, then kept in the vault (root only); it is not shown again.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
