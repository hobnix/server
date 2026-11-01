// What the row button of an app says and does (pure, no Svelte: tests/web-apps.mjs imports it in plain node).
// a: { state, vstate, applied, avail }. The button is never disabled for "up to date"; only a parked recipe disables it (in the page).
export function appAction(a) {
  if (a.state === 'parked') return { label: 'Install', icon: 'download-simple', tip: 'This recipe is parked', primary: false };
  if (a.state !== 'installed') return { label: 'Install', icon: 'download-simple', tip: 'Set this app up', primary: true };
  if (a.vstate === 'current') {
    return { label: 'Repair', icon: 'wrench', tip: `Up to date (version ${a.applied}). Run again only to repair the setup`, primary: false };
  }
  const tip = a.vstate === 'update'
    ? `Version ${a.avail} is available (applied: ${a.applied}). Run again to update`
    : 'Run again: repairs or updates the setup';
  return { label: 'Update', icon: 'arrows-clockwise', tip, primary: false };
}
