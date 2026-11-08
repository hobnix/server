<script>
  // Add an image: hs sys iso plan|start add <file-or-url> [--name <name.iso>] (--checksum <hex> | --no-checksum). The plan answers "needs checksum"
  // until one of the two is given; the download or copy is a background job (its progress is in the task list).
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { onclose, ondone } = $props();
  let kind = $state('url');
  let src = $state('');
  let name = $state('');
  let sum = $state('');
  let none = $state(false);

  const args = () => {
    const s = src.trim();
    if (!s) return null;
    const a = ['add', s];
    if (name.trim()) a.push('--name', name.trim());
    if (none) a.push('--no-checksum');
    else if (sum.trim()) a.push('--checksum', sum.trim());
    return a;
  };
  const plain = $derived(kind === 'url' && /^http:\/\//i.test(src.trim()));
</script>

<CreateDialog title="Add an ISO image" kicker="Add" area="iso" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <span class="lbl">Where is it</span>
      <div class="seg" role="radiogroup" aria-label="Where is it">
        <label class="seg-opt"><input type="radio" name="iso-kind" value="url" bind:group={kind} />From a URL</label>
        <label class="seg-opt"><input type="radio" name="iso-kind" value="path" bind:group={kind} />A file on this server</label>
      </div>
    </div>
    <div class="field">
      <label for="iso-src">{kind === 'url' ? 'URL' : 'Path of the file'}</label>
      <input id="iso-src" class="input" bind:value={src} placeholder={kind === 'url' ? 'https://cdimage.debian.org/.../debian-13-netinst.iso' : '/bulk/shares/isos/debian-13-netinst.iso'} autocomplete="off" spellcheck="false" />
      {#if plain}<div class="hint warn">This is a plain HTTP address: the download can be changed on the way. Prefer HTTPS and check the checksum.</div>{/if}
    </div>
    <div class="field">
      <label for="iso-sum">Checksum (SHA-256 or SHA-512)</label>
      <input id="iso-sum" class="input" bind:value={sum} disabled={none} placeholder="from the download page" autocomplete="off" spellcheck="false" />
      <label class="chk"><input type="checkbox" bind:checked={none} />There is no checksum: show me the computed one instead</label>
      <div class="hint">A wrong checksum deletes the file and fails the job, with both checksums shown. Without one nothing is verified.</div>
    </div>
    <div class="field">
      <label for="iso-name">Name in the library <span class="opt">(optional)</span></label>
      <input id="iso-name" class="input" bind:value={name} placeholder="taken from the file name" autocomplete="off" spellcheck="false" />
    </div>
  {/snippet}
</CreateDialog>

<style>
  .lbl { display: block; font-size: 12px; margin-bottom: 5px; color: var(--fg-2); }
  .opt { color: var(--fg-3); }
  .hint { font-size: 12px; color: var(--fg-3); margin-top: 4px; }
  .hint.warn { color: var(--warn-ink, var(--warn)); }
  .chk { display: flex; align-items: center; gap: 6px; font-size: 12.5px; margin-top: 6px; accent-color: var(--accent); }
</style>
