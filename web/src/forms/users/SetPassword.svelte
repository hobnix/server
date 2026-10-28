<script>
  // Set password: `hs sys users plan|start <user> password`, the new password on stdin.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import PasswordFields from './PasswordFields.svelte';

  let { user, ondone = () => {} } = $props();
  let pw = $state('');
  let pw2 = $state('');
  const pwOk = $derived(pw.length >= 8 && pw === pw2 && pw.length <= 256 && !/[\r\n\0]/.test(pw));
</script>

<CreateDialog title="Set password" kicker={user} area="users" args={() => (pwOk ? [user, 'password'] : null)} stdin={() => (pwOk ? pw : undefined)} {ondone}>
  {#snippet form()}
    <PasswordFields bind:pw bind:pw2 />
  {/snippet}
</CreateDialog>
