<script>
  // Move a folder (or file) from one SnapRAID data disk to another, disk to disk (hs sys disk plan|start <member> move --path <path> [--to <member>]).
  // The path in /bulk does not change: the same files are shown at the same paths before, during and after. The disk's own folders are browsed with
  // `hs sys disk ls` (one level at a time); nothing here ever touches /bulk itself, which is what makes it safe (a copy from a disk into the pool destroys the files).
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import { poll, rows } from '../../data.svelte.js';

  let { pool = 'bulk', member, targets = [] } = $props();

  let dir = $state('');        // the folder being looked at, relative to the disk ('' = the top)
  let picked = $state('');     // the folder or file chosen to move
  let to = $state('');

  const list = poll(() => `/api/sys/disk/ls/${member}${dir ? `?path=${encodeURIComponent(dir)}` : ''}`, 10000);
  // type d|f, bytes, name
  const entries = $derived(rows(list).map((r) => ({ dirp: r[0] === 'd', bytes: r[1], name: r[2] })));
  const crumbs = $derived(dir ? dir.split('/') : []);
  const others = $derived(targets.filter((n) => n !== member));
  const sizeTxt = (b) => (b === '' ? '' : b > 1e9 ? `${(b / 1e9).toFixed(1)} GB` : b > 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.ceil(b / 1e3)} kB`);
  const enter = (name) => { dir = dir ? `${dir}/${name}` : name; };
  const up = (n) => { dir = crumbs.slice(0, n).join('/'); };
  const pick = (name) => { picked = dir ? `${dir}/${name}` : name; };
  const args = () => (picked.includes('/') ? [member, 'move', '--path', picked, ...(to ? ['--to', to] : [])] : null);
</script>

<CreateDialog title="Move a folder to another disk" kicker="Pool" area="disk" {args}>
  {#snippet form()}
    <div class="field">
      <span class="lab">From data disk</span>
      <div class="fixed"><code>{member}</code> <span class="tag tag-neutral" style="padding:1px 7px">{pool}</span></div>
    </div>
    <div class="field">
      <span class="lab">Folder or file</span>
      <div class="crumbs">
        <button type="button" class="lnk" onclick={() => up(0)}>{member}</button>
        {#each crumbs as c, i}<span>/</span><button type="button" class="lnk" onclick={() => up(i + 1)}>{c}</button>{/each}
      </div>
      <ul class="files" aria-label="Contents of the folder">
        {#each entries as e}
          <li class:sel={picked === (dir ? `${dir}/${e.name}` : e.name)}>
            {#if e.dirp}
              <button type="button" class="lnk name" onclick={() => enter(e.name)} title="Open this folder"><i class="ph ph-folder"></i> {e.name}</button>
            {:else}
              <span class="name"><i class="ph ph-file"></i> {e.name}</span>
            {/if}
            <span class="sz">{sizeTxt(e.bytes)}</span>
            {#if dir}<button type="button" class="btn btn-ghost pick" onclick={() => pick(e.name)}>Choose</button>{/if}
          </li>
        {:else}
          <li class="sub">{list.loaded ? 'Nothing here.' : 'Loading…'}</li>
        {/each}
      </ul>
      {#if picked}<div class="hint">Chosen: <code>{picked}</code></div>{:else}<div class="hint">Open shares or sensitive, then choose the folder or file to move.</div>{/if}
    </div>
    <div class="field">
      <span class="lab">To data disk</span>
      <select class="input" bind:value={to} aria-label="Target disk">
        <option value="">The open disk with the most free space</option>
        {#each others as t}<option value={t}>{t}</option>{/each}
      </select>
    </div>
    <div class="hint">Disk to disk: /bulk shows the same files at the same paths the whole time. A file that the target already has is never overwritten. To put the files in another folder or share, rename them inside /bulk afterwards.</div>
  {/snippet}
</CreateDialog>

<style>
  .lab { display: block; font-size: 12px; margin-bottom: 5px; color: color-mix(in srgb, var(--color-text) 70%, transparent); }
  .fixed { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
  .crumbs { display: flex; flex-wrap: wrap; gap: 4px; align-items: center; font-size: 12.5px; margin-bottom: 6px; }
  .lnk { background: none; border: 0; padding: 0; color: var(--color-accent, inherit); cursor: pointer; font: inherit; text-align: left; }
  .files { list-style: none; margin: 0; padding: 0; max-height: 220px; overflow: auto; border: 1px solid var(--color-border, rgba(128,128,128,.3)); border-radius: var(--r); }
  .files li { display: flex; align-items: center; gap: 8px; padding: 5px 10px; font-size: 12.5px; }
  .files li.sel { background: color-mix(in srgb, var(--color-accent, #9184d9) 18%, transparent); }
  .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sz { color: var(--color-neutral-500); font-size: 11.5px; }
  .pick { padding: 1px 8px; font-size: 12px; }
</style>
