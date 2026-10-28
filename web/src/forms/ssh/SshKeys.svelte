<script>
  // SSH keys of adminuser: the list (`hs sys ssh-key list`: id, type, comment, session) with a remove button per key (plan dialog,
  // red, you type the word), and a field to add a public key (`hs sys ssh-key plan|start add <key>`). Both only change machine.toml;
  // the change takes effect with `hs rebuild` (the plan says so).
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { ui, openPlan } from '../../ui.svelte.js';

  let { ondone = () => {} } = $props();
  const list = poll('/api/sys/ssh-key/list', 5000);
  // id (fingerprint), type, comment ("-" = none), session (yes = the key of this SSH session)
  const keys = $derived(rows(list).map((r) => ({ id: r[0], type: r[1], comment: r[2] && r[2] !== '-' ? r[2] : '', session: r[3] === 'yes' })));

  let text = $state('');
  const line = $derived(text.trim().replace(/[ \t]+/g, ' '));
  const KEY_RE = /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]{16,700}={0,3}( [A-Za-z0-9@._:+=, -]{1,100})?$/;
  const oneLine = $derived(!/[\r\n]/.test(line));
  const shapeOk = $derived(line.length <= 800 && oneLine && KEY_RE.test(line));

  function remove(k) {
    ui.create = null;
    openPlan('ssh-key', ['remove', k.id], `Remove the SSH key ${k.comment || k.id}`);
  }
</script>

<CreateDialog title="SSH keys" kicker="Access" area="ssh-key" args={() => (shapeOk ? ['add', line] : null)} {ondone}>
  {#snippet form()}
    <div class="field">
      <div class="lbl">Keys that may log in as adminuser</div>
      <div class="tablescroll"><table class="table keys">
        <thead><tr><th>Comment</th><th class="opt">Type</th><th>Fingerprint</th><th></th></tr></thead>
        <tbody>
          {#each keys as k}
            <tr>
              <td>{k.comment || '(no comment)'}{#if k.session} <span class="tag tag-accent">this session</span>{/if}</td>
              <td class="n400 opt">{k.type}</td>
              <td class="n400 fp">{k.id}</td>
              <td class="act">
                <button class="btn btn-ghost danger icon" title={keys.length === 1 ? 'The last key cannot be removed' : k.session ? 'This is the key of your current SSH session' : 'Remove this key (shows the plan first)'}
                  disabled={keys.length === 1 || k.session} aria-label="Remove {k.comment || k.id}" onclick={() => remove(k)}><i class="ph ph-trash"></i></button>
              </td>
            </tr>
          {:else}
            <tr><td colspan="4" class="hint">{list.loaded ? (list.error ? 'The keys could not be read (storage locked?).' : 'No keys: nobody can log in over SSH.') : 'Loading…'}</td></tr>
          {/each}
        </tbody>
      </table></div>
    </div>
    <div class="field">
      <label for="sk-key">Add a key</label>
      <textarea id="sk-key" class="input" rows="4" bind:value={text} placeholder="ssh-ed25519 AAAA... name@pc" autocomplete="off" spellcheck="false"></textarea>
      {#if line && !oneLine}<div class="hint bad">One line only: the content of the .pub file.</div>
      {:else if line && !shapeOk}<div class="hint bad">That is not a public key line. It starts with ssh-ed25519, ssh-rsa or ecdsa-sha2-... and is the .pub file, never the private key.</div>{/if}
    </div>
    <div class="hint">Paste the line from <code>~/.ssh/id_ed25519.pub</code> on the PC that should get access. Adding or removing only changes machine.toml; it takes effect with <code>hs rebuild</code>.</div>
  {/snippet}
</CreateDialog>

<style>
  .lbl { font-size: 12px; color: var(--color-neutral-300); margin-bottom: 6px; }
  .keys { font-size: 12.5px; }
  @media (max-width: 860px) { .opt { display: none; } }
  .keys td, .keys th { padding: 5px 8px; text-align: left; }
  .n400 { color: var(--color-neutral-400); }
  .fp { font-family: monospace; font-size: 11px; word-break: break-all; }
  .act { text-align: right; white-space: nowrap; }
  .danger { color: var(--st-bad); }
  textarea.input { resize: vertical; font-family: monospace; font-size: 12px; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 4px; }
  .hint.bad { color: var(--st-bad); }
</style>
