<script>
  // Mount a share of another homeserver read only (hs sys peers plan|start add <peer> <host> <share> --user <login> [--domain <D>]).
  // The password of the login is one line on standard input: it never goes into the arguments or the job log.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone } = $props();

  let peer = $state('');
  let host = $state('');
  let share = $state('');
  let user = $state('');
  let domain = $state('');
  let pass = $state('');

  const args = () => {
    const p = peer.trim(), h = host.trim(), s = share.trim(), u = user.trim();
    if (!p || !h || !s || !u) return null;
    const a = ['add', p, h, s, '--user', u];
    if (domain.trim()) a.push('--domain', domain.trim());
    return a;
  };
  const stdin = () => (pass ? pass : undefined);
</script>

<CreateDialog title="Mount a share from another server" kicker="Remote shares" area="peers" {args} {stdin} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="pm-peer">Name for that server</label>
      <input id="pm-peer" class="input" bind:value={peer} placeholder="cousin" maxlength="20" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="pm-host">Its address</label>
      <input id="pm-host" class="input" bind:value={host} placeholder="homeserver2.local" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="pm-share">Share on that server</label>
      <input id="pm-share" class="input" bind:value={share} placeholder="media" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="pm-user">Login it gave you</label>
      <input id="pm-user" class="input" bind:value={user} placeholder="remote-yourserver" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="pm-domain">Domain (optional)</label>
      <input id="pm-domain" class="input" bind:value={domain} placeholder="HOME" autocomplete="off" spellcheck="false" />
    </div>
    <div class="field">
      <label for="pm-pass">Password</label>
      <input id="pm-pass" class="input" type="password" bind:value={pass} autocomplete="new-password" />
    </div>
    <div class="hint">Read only. It is not part of /bulk, the parity or the backup. The other server makes the login with “Give access…” on its Network page (or <code>hs remote offer</code>); the password is shown once.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
