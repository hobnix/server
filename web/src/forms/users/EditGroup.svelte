<script>
  // Edit a group: `hs sys users plan|start <group> group-edit --description <text>` ("-" clears it). The name of a group cannot be changed here.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { name, ondone = () => {} } = $props();
  const det = poll(`/api/sys/users/group-details/${encodeURIComponent(name)}`, 30000);
  const have = $derived(Object.fromEntries(rows(det).map((r) => [r[0], r[1] === '-' ? '' : (r[1] ?? '')])).description ?? '');
  let edited = $state(null);
  const desc = $derived(edited ?? have);
  const descOk = $derived(desc.length <= 255 && !/[\x00-\x1f\x7f]/.test(desc));
  const args = () => (det.loaded && desc !== have && descOk ? [name, 'group-edit', '--description', desc === '' ? '-' : desc] : null);
</script>

<CreateDialog title="Edit group" kicker={name} area="users" {args} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="eg-desc">Description</label>
      <input id="eg-desc" class="input" value={desc} oninput={(e) => (edited = e.currentTarget.value)} autocomplete="off" disabled={!det.loaded} />
      {#if !descOk}<div class="hint bad">One line, up to 255 characters.</div>{/if}
    </div>
    <div class="hint">The name of the group stays as it is. Members are chosen with Members; leave the field empty to clear the description.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 4px; }
  .hint.bad { color: var(--st-bad); }
</style>
