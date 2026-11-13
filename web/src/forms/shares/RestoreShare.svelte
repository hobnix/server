<script>
  // Restore from the backup: `hs sys shares plan|start <share> restore --snapshot <id|latest> [--path <inside>]`.
  // The files go into the share `restored`; the original is not touched.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { Field, TextInput, Select } from '../../ui';

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
    <Field label="Restore point">
      <Select bind:value={snapshot}>
        <option value="latest">latest</option>
        {#each list as s}<option value={s.id}>{s.id} · {s.time}</option>{/each}
      </Select>
    </Field>
    <Field label="Folder or file inside the share (optional)" error={pathOk ? '' : 'A path inside the share, without “..”.'}>
      <TextInput bind:value={path} placeholder="whole share" autocomplete="off" spellcheck={false} />
    </Field>
    <div class="hint">The files are restored into the share <code>restored</code>; the original is not touched.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12.5px; color: var(--color-neutral-400); }
</style>
