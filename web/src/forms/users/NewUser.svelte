<script>
  // New user: `hs sys users plan|start <name> user-add [--full <name>] [--group <group> ...]`, the password on stdin. The user starts in Domain Users;
  // every chosen group is joined by the job once the account exists (the plan lists one step per group).
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import PasswordFields from './PasswordFields.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { ondone = () => {} } = $props();
  let name = $state('');
  let full = $state('');
  let pw = $state('');
  let pw2 = $state('');
  let chosen = $state([]);

  const gl = poll('/api/sys/users/groups', 30000);
  // everyone is in Domain Users already; the script refuses it
  const groups = $derived(rows(gl).map((r) => r[0]).filter((n) => n.toLowerCase() !== 'domain users'));
  const toggle = (g) => { chosen = chosen.includes(g) ? chosen.filter((x) => x !== g) : [...chosen, g]; };

  const nameOk = $derived(/^[A-Za-z][A-Za-z0-9._-]{0,31}$/.test(name));
  const fullOk = $derived(full === '' || /^\w[\w .'-]{0,63}$/.test(full));
  const pwOk = $derived(pw.length >= 8 && pw === pw2 && pw.length <= 256 && !/[\r\n\0]/.test(pw));
  const args = () => (nameOk && fullOk && pwOk ? [name, 'user-add', ...(full ? ['--full', full] : []), ...chosen.flatMap((g) => ['--group', g])] : null);
  const adminWarn = $derived(chosen.some((g) => g.toLowerCase() === 'domain admins'));
</script>

<CreateDialog title="New user" area="users" {args} stdin={() => (pwOk ? pw : undefined)} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="nu-name">User name</label>
      <div class="pre"><span class="dom">HOME\</span><input id="nu-name" class="input" bind:value={name} placeholder="anna" autocomplete="off" spellcheck="false" /></div>
      {#if name && !nameOk}<div class="hint bad">Starts with a letter; letters, digits, dot, dash and underscore, up to 32.</div>{/if}
    </div>
    <div class="field">
      <label for="nu-full">Full name <span class="opt">(optional)</span></label>
      <input id="nu-full" class="input" bind:value={full} placeholder="Anna Muster" autocomplete="off" />
      {#if full && !fullOk}<div class="hint bad">Letters, digits, spaces, dot, dash and apostrophe only.</div>{/if}
    </div>
    <PasswordFields bind:pw bind:pw2 />
    <div class="field">
      <span class="lbl">Groups <span class="opt">(optional)</span></span>
      <div class="chips">
        {#each groups as g (g)}
          <button type="button" class="chip" class:on={chosen.includes(g)} aria-pressed={chosen.includes(g)} onclick={() => toggle(g)}>
            <i class="ph {chosen.includes(g) ? 'ph-check' : 'ph-plus'}"></i>{g}
          </button>
        {:else}
          <span class="hint">{gl.loaded ? 'No other groups yet.' : 'Loading…'}</span>
        {/each}
      </div>
    </div>
    {#if adminWarn}
      <div class="warn"><i class="ph ph-warning"></i>Domain Admins can sign in to this interface and change everything on the server.</div>
    {/if}
    <div class="hint">The new user is in Domain Users. What the chosen groups may open is set in Shares.</div>
  {/snippet}
</CreateDialog>

<style>
  .pre { display: flex; align-items: center; gap: 6px; }
  .dom { color: var(--color-neutral-400); font-size: 14px; }
  .opt { color: var(--color-neutral-500); }
  .lbl { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; }
  .chip { display: inline-flex; align-items: center; gap: 5px; font: inherit; font-size: 12.5px; padding: 4px 11px; border-radius: 999px; cursor: pointer;
    color: var(--color-neutral-300); background: transparent; border: 1px solid var(--color-divider); }
  .chip:hover { border-color: var(--color-accent); }
  .chip.on { background: var(--color-accent-800); color: var(--color-accent-100); border-color: transparent; }
  .warn { display: flex; gap: 8px; align-items: flex-start; font-size: 12.5px; color: var(--st-warn); }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 4px; }
  .hint.bad { color: var(--st-bad); }
</style>
