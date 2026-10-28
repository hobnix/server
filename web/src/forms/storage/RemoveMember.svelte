<script>
  // Remove a member (SnapRAID: a single disk) or detach one from a ZFS mirror (hs sys pool plan|start <pool> remove --member <name> [--mode detach|vdev|move|nomove]).
  // The plan is red and the server names the word to type (the disk).
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import ReplaceMember from './ReplaceMember.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { openCreate } from '../../ui.svelte.js';

  let { pool, member, snap = false } = $props();

  // Remove only works on a disk the server can read now (it moves its files, or leaves them on the disk). A disk that is MISSING or not mounted
  // cannot be removed: replacing it restores its files from the parity. Say so here instead of letting the plan refuse after a choice.
  const mem = poll(() => `/api/sys/pool/members?pool=${pool}`, 30000);
  // members: name, bytes, state (ONLINE|UNMOUNTED|MISSING ...), group, ...
  const state = $derived(rows(mem).find((r) => r[0] === member)?.[2] ?? '');
  const gone = $derived(snap && mem.loaded && state !== '' && state !== 'ONLINE');

  const snapData = $derived(snap && !member.startsWith('parity'));
  let mode = $state(snap ? 'move' : 'detach');

  const args = () => (gone ? null : [pool, 'remove', '--member', member, ...(snap && !snapData ? [] : ['--mode', mode])]);
</script>

<CreateDialog title={snap ? 'Remove a disk' : 'Detach a disk'} kicker="Pool" area="pool" {args}>
  {#snippet form()}
    <div class="field">
      <span class="lab">Member</span>
      <div class="fixed"><code>{member}</code> <span class="tag tag-neutral" style="padding:1px 7px">{pool}</span></div>
    </div>
    {#if gone}
      <div class="gone">
        <div><strong>{member} is {state}.</strong> {state === 'MISSING' ? 'The server cannot see the disk at all.' : 'The disk is there but not mounted.'}</div>
        <p>A disk cannot be removed while the server cannot read it: its files would be dropped from the array although the parity still holds them.
          <strong>Replace it</strong> with a new disk instead: its files are rebuilt from the parity (hours).</p>
        <p class="what">Before you replace it, look for a simple cause: the cable, the port and the power; an encrypted disk that is still locked (<code>hs unlock</code>);
          <code>hs disk list</code> and <code>lsblk -o NAME,LABEL,SIZE</code> show whether the disk is there at all. Replacing needs the parity to be in good order and no more
          disks missing than there are parity disks.</p>
        <button class="btn btn-primary" onclick={() => openCreate(ReplaceMember, { pool, member, snap })}><i class="ph ph-swap"></i>Replace {member}…</button>
      </div>
    {:else if !snap}
      <div class="field">
        <span class="lab">What happens to the mirror</span>
        <div class="seg" role="radiogroup" aria-label="Mode">
          <label class="seg-opt"><input type="radio" name="rm-mode" checked={mode === 'detach'} onchange={() => (mode = 'detach')} />Detach this disk</label>
          <label class="seg-opt"><input type="radio" name="rm-mode" checked={mode === 'vdev'} onchange={() => (mode = 'vdev')} />Remove the whole mirror</label>
        </div>
        <div class="hint">{mode === 'detach' ? 'The other disk of the mirror stays alone; nothing moves.' : 'The data moves to the other mirrors first; both disks leave the pool.'}</div>
      </div>
    {:else if snapData}
      <div class="field">
        <span class="lab">What happens to the files on this disk</span>
        <div class="seg" role="radiogroup" aria-label="Mode">
          <label class="seg-opt"><input type="radio" name="rm-mode" checked={mode === 'move'} onchange={() => (mode = 'move')} />Move them to the other disks</label>
          <label class="seg-opt"><input type="radio" name="rm-mode" checked={mode === 'nomove'} onchange={() => (mode = 'nomove')} />Leave them on the disk</label>
        </div>
        <div class="hint">{mode === 'move' ? 'The files move to the other disks first. That can take hours; it runs as a background job.' : 'Nothing moves. Files still on the disk are no longer in /bulk (the disk is not erased); use this for a disk you emptied already.'}</div>
      </div>
    {:else}
      <div class="hint">The parity disk is unlabelled and leaves the array; nothing is erased.</div>
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .gone { display: flex; flex-direction: column; gap: 6px; padding: 12px 14px; border-radius: var(--r); background: var(--color-neutral-900); box-shadow: inset 0 0 0 1px var(--st-warn); font-size: 13px; }
  .gone p { margin: 0; }
  .gone .what { font-size: 12px; color: var(--color-neutral-400); }
  .gone .btn { align-self: flex-start; margin-top: 4px; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
</style>
