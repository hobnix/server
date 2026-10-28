<script>
  // Edit a user: `hs sys users plan|start <user> user-edit [--full <name>] [--mail <address>] [--description <text>]`. Only the fields that differ from what
  // the domain holds are sent; "-" clears a field. The login name cannot be changed here.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { user, ondone = () => {} } = $props();
  const det = poll(`/api/sys/users/details/${encodeURIComponent(user)}`, 30000);
  const have = $derived(Object.fromEntries(rows(det).map((r) => [r[0], r[1] === '-' ? '' : (r[1] ?? '')])));
  let edited = $state({});
  const val = (k) => (k in edited ? edited[k] : (have[k] ?? ''));

  const fullOk = $derived(val('full') === '' || /^\w[\w .'-]{0,63}$/.test(val('full')));
  const mailOk = $derived(val('mail') === '' || /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}$/.test(val('mail')));
  const descOk = $derived(val('description').length <= 255 && !/[\x00-\x1f\x7f]/.test(val('description')));
  const changed = $derived(['full', 'mail', 'description'].filter((k) => det.loaded && val(k) !== (have[k] ?? '')));
  const flag = { full: '--full', mail: '--mail', description: '--description' };
  const args = () => (det.loaded && changed.length && fullOk && mailOk && descOk
    ? [user, 'user-edit', ...changed.flatMap((k) => [flag[k], val(k) === '' ? '-' : val(k)])] : null);
</script>

<CreateDialog title="Edit user" kicker={user} area="users" {args} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="eu-full">Full name</label>
      <input id="eu-full" class="input" value={val('full')} oninput={(e) => (edited.full = e.currentTarget.value)} placeholder="Anna Muster" autocomplete="off" disabled={!det.loaded} />
      {#if !fullOk}<div class="hint bad">Letters, digits, spaces, dot, dash and apostrophe only.</div>{/if}
    </div>
    <div class="field">
      <label for="eu-mail">Email</label>
      <input id="eu-mail" class="input" type="email" value={val('mail')} oninput={(e) => (edited.mail = e.currentTarget.value)} placeholder="anna@example.org" autocomplete="off" disabled={!det.loaded} />
      {#if !mailOk}<div class="hint bad">This is not an email address.</div>{/if}
    </div>
    <div class="field">
      <label for="eu-desc">Description</label>
      <input id="eu-desc" class="input" value={val('description')} oninput={(e) => (edited.description = e.currentTarget.value)} autocomplete="off" disabled={!det.loaded} />
      {#if !descOk}<div class="hint bad">One line, up to 255 characters.</div>{/if}
    </div>
    <div class="hint">The login name stays as it is. Leave a field empty to clear it.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 4px; }
  .hint.bad { color: var(--st-bad); }
</style>
