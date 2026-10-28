<script>
  // New group: `hs sys users plan|start <name> group-add [--access <share>=read|write|full ...]`. A share left on "none" gets no entry; the job gives the
  // new group the chosen levels (manage-shares.sh --set) as soon as the domain knows its SID.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { existing = [], ondone = () => {} } = $props();
  let name = $state('');
  let levels = $state({});
  const nameOk = $derived(/^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$/.test(name) && !/ $/.test(name));
  const taken = $derived(existing.some((g) => g.toLowerCase() === name.toLowerCase()));

  const sh = poll('/api/sys/shares/overview', 60000);
  // name, kind, ... ; "other" rows are not shares of the file server
  const shares = $derived(rows(sh).filter((r) => r[1] !== 'other' && /^[a-z0-9][a-z0-9-]{0,40}$/.test(r[0])).map((r) => r[0]));
  const levelOf = (s) => levels[s] ?? 'none';
  const args = () => (nameOk && !taken
    ? [name, 'group-add', ...shares.filter((s) => levelOf(s) !== 'none').flatMap((s) => ['--access', `${s}=${levelOf(s)}`])]
    : null);
</script>

<CreateDialog title="New group" area="users" {args} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="ng-name">Group name</label>
      <input id="ng-name" class="input" bind:value={name} placeholder="Family" autocomplete="off" spellcheck="false" />
      {#if name && !nameOk}<div class="hint bad">Letters, digits, space, dot, dash and underscore; starts with a letter or digit.</div>{/if}
      {#if taken}<div class="hint bad">There is a group with this name already.</div>{/if}
    </div>
    <div class="field">
      <span class="lbl">Access to shares <span class="opt">(optional)</span></span>
      <div class="grid">
        {#each shares as s (s)}
          <span class="sn">{s}</span>
          <div class="seg" role="radiogroup" aria-label="Access to {s}">
            {#each ['none', 'read', 'write', 'full'] as l}
              <label class="seg-opt"><input type="radio" name="ng-{s}" value={l} checked={levelOf(s) === l} onchange={() => (levels = { ...levels, [s]: l })} />{l}</label>
            {/each}
          </div>
        {:else}
          <span class="hint">{sh.loaded ? (sh.error ? 'The shares could not be read.' : 'No shares yet.') : 'Loading…'}</span>
        {/each}
      </div>
    </div>
    <div class="hint">A new group has no members. Add them with the Members button. Levels can be changed later in Shares.</div>
  {/snippet}
</CreateDialog>

<style>
  .lbl { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .opt { color: var(--color-neutral-500); }
  .grid { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 6px 12px; align-items: center; max-height: 280px; overflow: auto; }
  .sn { font-size: 13px; overflow: hidden; text-overflow: ellipsis; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 4px; }
  .hint.bad { color: var(--st-bad); }
</style>
