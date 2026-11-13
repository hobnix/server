<script>
  // Rename: `hs sys shares plan|start <share> rename --to <new name>` (the plan lists the instances that restart).
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { Field, TextInput } from '../../ui';

  let { share, onclose, ondone = () => {} } = $props();
  let to = $state('');
  const ok = $derived(/^[a-z0-9][a-z0-9-]{0,40}$/.test(to) && to !== share);
  const args = () => (ok ? [share, 'rename', '--to', to] : null);
</script>

<CreateDialog title="Rename {share}" kicker="Change" area="shares" {args} {onclose} {ondone}>
  {#snippet form()}
    <Field label="New name" error={to && !ok ? 'Lowercase letters, digits and “-”, different from the current name.' : ''}>
      <TextInput bind:value={to} placeholder={share} autocomplete="off" spellcheck={false} />
    </Field>
    <div class="hint">The folder on every disk, the Samba share with its permissions, the backup switch and the mounts of instances move to the new name.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12.5px; color: var(--color-neutral-400); }
</style>
