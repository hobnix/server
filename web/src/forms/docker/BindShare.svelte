<script>
  // Bind a share into an app: the dialog builds ONE volume line (`<mount>/<subfolder>:<container path>[:ro]`) and hands it to the editor.
  // Docker sees a share at /shares/<share>. A share that is mounted already needs no change: the line is inserted at once (onsubmit).
  // A share that is not mounted yet is a change of the container docker (one fixed mapped user; the user mapping changes, so Docker restarts and
  // every app in it): the second step shows that, and Continue (onmount) opens the usual plan, whose steps carry the same warning.
  //   props: shares [names], peers [{ peer, shares: [names] }] (mounted remote offers), mounts (volumes.js mountsOf), mapped ('uid:gid' or ''),
  //   listDir(share, path) -> Promise<[folder names]>, onsubmit(line), onmount({ args, line }), onclose()
  import Combobox from '../../ui/Combobox.svelte';
  import Button from '../../ui/Button.svelte';
  import {
    findMount, mountPathOf, joinHost, volumeEntryText, mountArgs, validContainerPath, validSub, validShareValue, DEFAULT_AS,
  } from '../../editor/volumes.js';

  let { shares = [], peers = [], mounts = [], mapped = '', listDir = async () => [], onsubmit, onmount, onclose } = $props();

  let share = $state('');
  let sub = $state('');
  let cpath = $state('');
  let ro = $state(false);
  let step = $state(1);
  let folders = $state([]);
  let asText = $state('');

  const options = $derived([
    ...shares.map((s) => ({ value: s, label: s })),
    ...peers.map((p) => ({ value: `remote:${p.peer}`, label: `${p.peer} (another server, read only)` })),
  ]);
  const remote = $derived(share.startsWith('remote:'));
  const peer = $derived(remote ? peers.find((p) => `remote:${p.peer}` === share) : null);
  const mount = $derived(share ? findMount(mounts, remote ? { peer: share.slice(7) } : { share }) : undefined);
  const mountPath = $derived(mount ? mount.path : share ? mountPathOf(remote ? share.slice(7) : share) : '');
  const as = $derived(asText.trim() || mapped || DEFAULT_AS);
  const asOk = $derived(!asText.trim() || /^[0-9]{1,10}:[0-9]{1,10}$/.test(asText.trim()));
  const forcedRo = $derived(remote || !!mount?.ro);
  const effRo = $derived(forcedRo || ro);
  const valid = $derived(!!share && validShareValue(share) && validContainerPath(cpath) && validSub(sub) && asOk);
  const line = $derived(valid ? volumeEntryText({ host: joinHost(mountPath, sub), cpath, ro: effRo }) : '');

  // the folders of the share (a remote offer: its shares), asked when the share changes
  let seq = 0;
  $effect(() => {
    const s = share;
    const my = ++seq;
    folders = [];
    if (!s) return;
    if (s.startsWith('remote:')) { folders = (peer?.shares ?? []).slice(); return; }
    listDir(s, '/').then((l) => { if (my === seq) folders = l; }, () => {});
  });
  const subOptions = $derived([{ value: '', label: '(the whole share)' }, ...folders.map((f) => ({ value: f, label: f }))]);

  function next() {
    if (!valid) return;
    if (mount) { onsubmit(line); return; }
    step = 2;
  }
  function mountIt() {
    if (!valid || mount) return;
    onmount({ args: mountArgs(share, mountPath, remote ? '' : asText.trim()), line });
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onclose()} />

<div class="dialog-backdrop" role="presentation">
  <div class="dialog" role="dialog" aria-modal="true" aria-labelledby="bs-t">
    <div class="dialog-title" id="bs-t">Bind a share</div>
    {#if step === 1}
      <div class="dialog-body">Adds one volume line to the service your cursor is in. Docker sees a share at <code>/shares/&lt;share&gt;</code>.</div>
      <div class="field">
        <label for="bs-share">Share</label>
        <Combobox id="bs-share" wide options={options} bind:value={share} placeholder="Choose a share" />
      </div>
      <div class="field">
        <label for="bs-sub">Subfolder</label>
        <Combobox id="bs-sub" wide options={subOptions} bind:value={sub} placeholder="(the whole share)" disabled={!share} />
      </div>
      <div class="field">
        <label for="bs-path">Path in the container</label>
        <input id="bs-path" class="input" bind:value={cpath} placeholder="/data" maxlength="200" autocomplete="off" autocapitalize="off" spellcheck="false" />
      </div>
      <label class="check"><input type="checkbox" checked={effRo} disabled={forcedRo} onchange={(e) => { ro = e.currentTarget.checked; }} /> Read only{forcedRo ? ' (this share is read only here)' : ''}</label>
      {#if line}<code class="preview">- {line}</code>{/if}
      {#if share && !mount}<div class="hint">{remote ? `${share.slice(7)} is not in Docker yet: the next step adds it.` : `${share} is not in Docker yet: the next step gives it to Docker.`}</div>{/if}
    {:else}
      <div class="dialog-body">
        {#if remote}
          Add the shares of <code>{share.slice(7)}</code> to Docker at <code>{mountPath}</code>, read only.
        {:else}
          Mount <code>{share}</code> into Docker at <code>{mountPath}</code> as <code>{as}</code>.
        {/if}
      </div>
      {#if !remote}
        <div class="warn">Docker has one user for all shares. A changed user mapping restarts Docker, and with it every app in it. The plan lists the running apps.</div>
        <div class="field">
          <label for="bs-as">User (uid:gid)</label>
          <input id="bs-as" class="input" bind:value={asText} placeholder={mapped || DEFAULT_AS} maxlength="21" autocomplete="off" spellcheck="false" />
          <div class="hint">{mapped ? `Docker maps ${mapped} already; leave this empty to keep it.` : `Empty means ${DEFAULT_AS}. The app's PUID and PGID in .env should be the same.`}</div>
        </div>
      {/if}
      <div class="hint">After the job the line <code>- {line}</code> is added to your compose file.</div>
    {/if}
    <div class="dialog-actions">
      <Button onclick={onclose}>Cancel</Button>
      {#if step === 2}<Button onclick={() => { step = 1; }}>Back</Button>{/if}
      {#if step === 1}
        <Button variant="primary" disabled={!valid} tooltip={valid ? '' : 'Choose a share and an absolute path in the container'} onclick={next}>{mount ? 'Insert' : 'Next'}</Button>
      {:else}
        <Button variant="primary" disabled={!valid} onclick={mountIt}>Show the plan</Button>
      {/if}
    </div>
  </div>
</div>

<style>
  .field { display: flex; flex-direction: column; gap: 4px; }
  .field label { font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-3); }
  .check { display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--fg-2); }
  .preview { display: block; padding: 8px 10px; border: 1px solid var(--line); background: var(--panel-2); color: var(--fg-2); font-size: 12px; overflow-wrap: anywhere; }
  .hint { font-size: 12px; color: var(--fg-3); }
  .warn { font-size: 12.5px; color: var(--warn); border-left: 3px solid var(--warn); padding: 4px 10px; }
</style>
