<script>
  // Group membership: `hs sys users plan|start <name> membership --change <user>:<group>=add|remove ...`.
  // subject "user": the chips are groups, the dialog edits the groups of `name`. subject "group": the chips are users, it edits the members of `name`.
  // `have` = what is true now (group names of the user, or user names of the group), `options` = everything that can be chosen.
  import CreateDialog from '../../shell/CreateDialog.svelte';

  let { subject, name, have = [], options = [], ondone = () => {} } = $props();
  const initial = () => new Set(have.map((x) => x.toLowerCase()));
  let on = $state(initial());

  const pick = $derived(options.filter((o) => o.toLowerCase() !== 'domain users'));
  const toggle = (o) => {
    const k = o.toLowerCase();
    const next = new Set(on);
    if (next.has(k)) next.delete(k); else next.add(k);
    on = next;
  };
  // one --change per difference; a change is <user>:<group>=add|remove
  const changes = $derived(pick.flatMap((o) => {
    const was = initial().has(o.toLowerCase());
    const now = on.has(o.toLowerCase());
    if (was === now) return [];
    const [u, g] = subject === 'user' ? [name, o] : [o, name];
    return [`${u}:${g}=${now ? 'add' : 'remove'}`];
  }));
  const args = () => [name, 'membership', ...changes.flatMap((c) => ['--change', c])];
  const adminWarn = $derived(subject === 'user' ? on.has('domain admins') && !initial().has('domain admins') : name.toLowerCase() === 'domain admins' && changes.some((c) => c.endsWith('=add')));
</script>

<CreateDialog title={subject === 'user' ? 'Groups of ' + name : 'Members of ' + name} kicker="Edit" area="users" {args} {ondone}>
  {#snippet form()}
    <div class="field">
      <span class="lbl">{subject === 'user' ? 'Groups' : 'Members'}</span>
      <div class="chips">
        {#each pick as o (o)}
          <button type="button" class="chip" class:on={on.has(o.toLowerCase())} aria-pressed={on.has(o.toLowerCase())} onclick={() => toggle(o)}>
            <i class="ph {on.has(o.toLowerCase()) ? 'ph-check' : 'ph-plus'}"></i>{o}
          </button>
        {:else}
          <span class="hint">Nothing to choose from.</span>
        {/each}
      </div>
      <div class="hint">Every user is in Domain Users; that cannot be changed here.</div>
    </div>
    {#if adminWarn}
      <div class="warn"><i class="ph ph-warning"></i>Domain Admins can sign in to this interface and change everything on the server.</div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .lbl { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; }
  .chip { display: inline-flex; align-items: center; gap: 5px; font: inherit; font-size: 12.5px; padding: 4px 11px; border-radius: 999px; cursor: pointer;
    color: var(--color-neutral-300); background: transparent; border: 1px solid var(--color-divider); }
  .chip:hover { border-color: var(--color-accent); }
  .chip.on { background: var(--color-accent-800); color: var(--color-accent-100); border-color: transparent; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 6px; }
  .warn { display: flex; gap: 8px; align-items: flex-start; font-size: 12.5px; color: var(--st-warn); }
</style>
