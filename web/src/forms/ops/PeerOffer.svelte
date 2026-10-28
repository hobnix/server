<script>
  // Give another homeserver read access to a share (hs sys peers plan|start offer <peer> <share> [--new-password]).
  // The answer of start holds the new password once (`secret`): ondone gets it and the page shows it in PeerOffered; it is never a job and never logged.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone = () => {}, peer: peer0 = '', share: share0 = '', newpw: newpw0 = false } = $props();

  let peer = $state(peer0);
  let share = $state(share0);
  let newpw = $state(newpw0);

  const args = () => {
    const p = peer.trim(), s = share.trim();
    if (!/^[a-z0-9][a-z0-9-]{0,19}$/.test(p) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(s)) return null;
    const a = ['offer', p, s];
    if (newpw) a.push('--new-password');
    return a;
  };
</script>

<CreateDialog title="Give access to a share" kicker="Remote shares" area="peers" {args} {onclose} ondone={(r) => ondone({ ...r, peer: peer.trim(), share: share.trim() })}>
  {#snippet form()}
    <div class="field">
      <label for="po-peer">Name for that server</label>
      <input id="po-peer" class="input" bind:value={peer} placeholder="cousin" maxlength="20" autocomplete="off" spellcheck="false" readonly={!!peer0} />
    </div>
    <div class="field">
      <label for="po-share">Share it may read</label>
      <input id="po-share" class="input" bind:value={share} placeholder="media" autocomplete="off" spellcheck="false" readonly={!!share0} />
    </div>
    <label class="check"><input type="checkbox" bind:checked={newpw} disabled={newpw0} /> Make a new password (the old one stops working)</label>
    <div class="hint">The login <code>remote-{peer || 'name'}</code> can read this share and nothing else. The password is shown once, after this step.</div>
  {/snippet}
</CreateDialog>

<style>
  .check { display: flex; gap: 8px; align-items: center; font-size: 12.5px; color: var(--color-neutral-300); }
  .hint { font-size: 12px; color: var(--color-neutral-500); }
</style>
