<script>
  // The shortcut list (the `?` overlay). Every key is also a button in the toolbar.
  import { backdropClose } from '../ui/backdrop.js';

  let { onclose } = $props();
  const GROUPS = [
    { t: 'Move around', k: [['↑ ↓', 'Move the cursor'], ['Enter', 'Open the folder (or show the info of a file)'], ['Backspace', 'Up one folder'], ['Tab', 'Switch to the other pane'], ['/', 'Filter the list'], ['Ctrl R', 'Read the lists again']] },
    { t: 'Select', k: [['Click', 'Select one'], ['Ctrl/Cmd click', 'Add or remove one'], ['Shift click', 'Select a range'], ['Space / Insert', 'Toggle and go down'], ['Ctrl A', 'Select all'], ['*', 'Invert the selection'], ['+  and  −', 'Select or deselect by pattern, such as *.mkv'], ['Esc', 'Clear the selection']] },
    { t: 'Do', k: [['F2', 'Rename'], ['F3', 'Info'], ['F5', 'Copy to the other pane'], ['F6', 'Move to the other pane'], ['F7', 'New folder'], ['F8 / Delete', 'Delete'], ['Drag', 'Copy to the other pane or into a folder (Shift: move)'], ['?', 'This list']] },
  ];
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (e.stopPropagation(), onclose())} />

<div class="dialog-backdrop" role="presentation" use:backdropClose={onclose}>
  <div class="kdlg" role="dialog" aria-modal="true" aria-labelledby="fmkt">
    <div class="dh"><span class="eyebrow">Files</span><h3 id="fmkt">Keyboard shortcuts</h3></div>
    <div class="body">
      {#each GROUPS as g}
        <div class="grp"><div class="eyebrow">{g.t}</div>
          {#each g.k as [k, d]}<div class="row"><kbd>{k}</kbd><span>{d}</span></div>{/each}
        </div>
      {/each}
      <p class="foot">Nothing starts from a key: copy, move, rename, new folder and delete open a plan first.</p>
    </div>
    <div class="dfoot"><button class="btn btn-primary" onclick={onclose}>Close</button></div>
  </div>
</div>

<style>
  .kdlg { width: min(640px, 100%); max-height: calc(100dvh - 32px); display: flex; flex-direction: column; overflow: hidden; background: var(--panel); border: 1px solid var(--line-2); border-radius: var(--r); box-shadow: 0 24px 64px oklch(0 0 0 / 0.5); }
  .dh { padding: 18px 22px 12px; border-bottom: 1px solid var(--line); }
  h3 { margin: 4px 0 0; font-size: 18px; }
  .body { padding: 12px 22px; overflow: auto; display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 18px; }
  .grp { display: flex; flex-direction: column; gap: 6px; }
  .row { display: flex; gap: 10px; align-items: baseline; font-size: 12.5px; color: var(--fg-2); }
  kbd { flex: none; min-width: 78px; font: 500 11.5px var(--mono); color: var(--fg); padding: 1px 6px; border: 1px solid var(--line-2); background: var(--panel-2); white-space: nowrap; }
  .foot { grid-column: 1 / -1; margin: 0; font-size: 12.5px; color: var(--fg-3); }
  .dfoot { display: flex; justify-content: flex-end; padding: 12px 22px; background: var(--panel-2); border-top: 1px solid var(--line); }
  @media (max-width: 860px) { .kdlg { width: calc(100% + 32px); margin: -16px; height: 100dvh; max-height: none; } }
</style>
