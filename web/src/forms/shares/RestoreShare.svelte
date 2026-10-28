<script>
  // Restore from the backup: `hs sys shares plan|start <share> restore --snapshot <id|latest> [--path <inside>]`.
  // The files go into the share `restored`; the original is not touched.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { share, onclose, ondone = () => {} } = $props();

  const snaps = poll('/api/sys/backup/snapshots?tag=shares', 60000);
  // id, time, tags; newest first
  const list = $derived(rows(snaps).map((r) => ({ id: r[0], time: r[1] })).reverse());

  let snapshot = $state('latest');
  let path = $state('');
  const pathOk = $derived(path === '' || (/^\/?[A-Za-z0-9_][A-Za-z0-9._\/ -]*$/.test(path) && !path.includes('..')));
  const args = () => {
    if (!pathOk || !/^(latest|[A-Za-z0-9]{1,64})$/.test(snapshot)) return null;
    const a = [share, 'restore', '--snapshot', snapshot];
    if (path) a.push('--path', path);
    return a;
  };
</script>

<CreateDialog title="Restore {share} from backup" kicker="Restore" area="shares" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="rs-snap">Restore point</label>
      <select id="rs-snap" class="input" bind:value={snapshot}>
        <option value="latest">latest</option>
        {#each list as s}<option value={s.id}>{s.id} · {s.time}</option>{/each}
      </select>
    </div>
    <div class="field">
      <label for="rs-path">Folder or file inside the share (optional)</label>
      <input id="rs-path" class="input" bind:value={path} placeholder="whole share" autocomplete="off" spellcheck="false" />
      {#if !pathOk}<div class="err">A path inside the share, without “..”.</div>{/if}
    </div>
    <div class="hint">The files are restored into the share <code>restored</code>; the original is not touched.</div>
  {/snippet}
</CreateDialog>

<style>
  .err { font-size: 12px; color: var(--st-bad); margin-top: 4px; }
  .hint { font-size: 12.5px; color: var(--color-neutral-400); }
</style>
