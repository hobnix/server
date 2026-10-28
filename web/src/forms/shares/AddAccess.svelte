<script>
  // Give a user or group access: `hs sys shares plan|start <share> perm --set <sid>=<level>`; the principals come from /api/sys/shares/principals.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  // taken: the SIDs that already have an entry
  let { share, taken = [], onclose, ondone = () => {} } = $props();

  const pr = poll('/api/sys/shares/principals', 60000);
  // sid, name, user|group
  const people = $derived(rows(pr).map((r) => ({ sid: r[0], name: r[1], type: r[2] })).filter((p) => !taken.includes(p.sid)));

  let sid = $state('');
  let level = $state('read');
  const args = () => (/^S-1-[0-9]+(-[0-9]+)+$/.test(sid) ? [share, 'perm', '--set', `${sid}=${level}`] : null);
</script>

<CreateDialog title="Add access to {share}" kicker="Permissions" area="shares" {args} {onclose} {ondone}>
  {#snippet form()}
    <div class="field">
      <label for="aa-who">User or group</label>
      <select id="aa-who" class="input" bind:value={sid}>
        <option value="">{pr.loaded ? 'Choose…' : 'Loading…'}</option>
        {#each people as p}<option value={p.sid}>{p.name} ({p.type})</option>{/each}
      </select>
      {#if pr.loaded && !people.length}<div class="hint">{pr.error ? 'The users could not be read.' : 'Everyone already has an entry.'}</div>{/if}
    </div>
    <div class="field">
      <label for="aa-level">Access</label>
      <div class="seg" id="aa-level">
        {#each ['none', 'read', 'write', 'full'] as l}
          <label class="seg-opt"><input type="radio" bind:group={level} value={l} />{l}</label>
        {/each}
      </div>
    </div>
    <div class="hint">Permissions apply at the next connection.</div>
  {/snippet}
</CreateDialog>

<style>
  .hint { font-size: 12.5px; color: var(--color-neutral-400); margin-top: 6px; }
</style>
