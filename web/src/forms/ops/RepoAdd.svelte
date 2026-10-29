<script>
  // Add a package repository: hs sys pkg plan|start repo-add <name> <url>, the public signing key as the one line on standard input. Only a signed
  // repository can be added here; the release is fetched at once and the repository is not kept when nothing verifies.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone } = $props();

  let name = $state('');
  let url = $state('');
  let key = $state('');

  const args = () => {
    const n = name.trim();
    const u = url.trim();
    if (!n || !u) return null;
    return ['repo-add', n, u];
  };
  // one line: the first non-empty line of what was pasted
  const stdin = () => key.split('\n').map((l) => l.trim()).find((l) => l) ?? '';
</script>

<CreateDialog title="Add a repository" kicker="Add" area="pkg" {args} {stdin} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="rp-name">Name</label>
      <input id="rp-name" class="input" bind:value={name} placeholder="friends" maxlength="41" autocomplete="off" spellcheck="false" />
      <div class="hint">Lower case letters, digits and dashes.</div>
    </div>
    <div class="field">
      <label for="rp-url">Address</label>
      <input id="rp-url" class="input" bind:value={url} placeholder="https://github.com/someone/recipes" autocomplete="off" spellcheck="false" />
      <div class="hint">https://…, ssh://git@… or git@host:path</div>
    </div>
    <div class="field">
      <label for="rp-key">Public signing key</label>
      <textarea id="rp-key" class="input key" rows="3" bind:value={key} placeholder="ssh-ed25519 AAAA… release" autocomplete="off" spellcheck="false"></textarea>
      <div class="hint">The public half of the key that signs the releases, from the owner of the repository (a line that starts with ssh-ed25519 or ssh-rsa). Only releases signed with it are used.</div>
    </div>
    <div class="hint">What a package installs runs as root on this server. Only add a repository whose owner you trust.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12px; color: var(--fg-3); margin-top: 3px; }
  .key { font-family: var(--mono); font-size: 12px; resize: vertical; }
</style>
