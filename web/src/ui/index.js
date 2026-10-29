// The shared components of the redesign, one per job (web/design/HANDOFF.md "Shared components"). Props are documented at the top of each file.
// Phase-2 pages import from here (or from the file directly) and never hand-draw a dot, bar, banner, drawer or select.
export { default as StatusDot } from './StatusDot.svelte';
export { default as Chip } from './Chip.svelte';
export { default as Banner } from './Banner.svelte';
export { default as EmptyState } from './EmptyState.svelte';
export { default as Skeleton } from './Skeleton.svelte';
export { default as Switch } from './Switch.svelte';          // also the checkbox: <Switch box>
export { default as Combobox } from './Combobox.svelte';
export { default as Drawer } from './Drawer.svelte';
export { default as Kv } from './Kv.svelte';
export { default as Split } from './Split.svelte';
// elsewhere, kept at their old paths so pages keep working:
//   shell/Table.svelte, shell/UsageBar.svelte, shell/Spark.svelte, shell/PlanDialog.svelte (opened with openPlan), forms/unlock/UnlockForm.svelte
// new in shell/: Halftone, PageHeader, PageState (loading, empty, error with stale data), PageFrame (locked, off, unreachable: the shell does it)
export { default as Tooltip } from './Tooltip.svelte';   // mounted once in App.svelte; a control asks for it: <button use:tip={'text'}>
export { tip } from './tooltip.svelte.js';
export { backdropClose } from './backdrop.js';           // read-only dialogs only: <div class="dialog-backdrop" use:backdropClose={close}>
