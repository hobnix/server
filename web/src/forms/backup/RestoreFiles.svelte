<script>
  // Restore files from the backup: `hs sys shares plan|start <share> restore --snapshot <id|latest> [--path <inside>]` (scripts/share-change.sh,
  // which runs `hs backup restore`). The files land in the share `restored` below their full original path; the original is never touched and
  // nothing but the restored subtree changes owner. A share that was deleted can still be typed in: that is what a restore is for.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { share: first = '', onclose, ondone = () => {} } = $props();

  const ov = poll('/api/sys/backup/overview', 60000);
  const snaps = poll('/api/sys/backup/snapshots?tag=shares', 60000);
  // kind, name, on|off, bytes
  const names = $derived(rows(ov).filter((r) => r[0] === 'shares' || r[0] === 'sensitive').map((r) => r[1]));
  // id, time, tags; newest first
  const list = $derived(rows(snaps).map((r) => ({ id: r[0], time: r[1] })).reverse());

  let share = $state(first);
  let snapshot = $state('latest');
  let path = $state('');
  const shareOk = $derived(/^[a-z0-9][a-z0-9-]{0,40}$/.test(share));
  const pathOk = $derived(path === '' || (/^\/?[A-Za-z0-9_][A-Za-z0-9._\/ -]*$/.test(path) && !path.includes('..')));
  const args = () => {
    if (!shareOk || !pathOk || !/^(latest|[A-Za-z0-9]{1,64})$/.test(snapshot)) return null;
    const a = [share, 'restore', '--snapshot', snapshot];
    if (path) a.push('--path', path);
    return a;
  };
</script>

<CreateDialog title="Restore files from the backup" kicker="Restore" area="shares" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="rf-share">Share</label>
      <input id="rf-share" class="input" list="rf-shares" bind:value={share} placeholder="photos" autocomplete="off" spellcheck="false" />
      <datalist id="rf-shares">{#each names as n}<option value={n}></option>{/each}</datalist>
      {#if share && !shareOk}<div class="err">A share name: lower-case letters, digits and hyphens.</div>{/if}
    </div>
    <div class="field">
      <label for="rf-snap">Restore point</label>
      <select id="rf-snap" class="input" bind:value={snapshot}>
        <option value="latest">latest</option>
        {#each list as s}<option value={s.id}>{s.id} · {s.time}</option>{/each}
      </select>
    </div>
    <div class="field">
      <label for="rf-path">Folder or file inside the share (optional)</label>
      <input id="rf-path" class="input" bind:value={path} placeholder="whole share" autocomplete="off" spellcheck="false" />
      {#if !pathOk}<div class="err">A path inside the share, without “..”.</div>{/if}
    </div>
    <div class="hint">The files are restored into the share <code>restored</code> (created when it does not exist), below their full original path. The original is not touched: copy back what you need.</div>
  {/snippet}
</CreateDialog>

<style>
  .err { font-size: 12px; color: var(--st-bad); margin-top: 4px; }
  .hint { font-size: 12.5px; color: var(--color-neutral-400); }
</style>
