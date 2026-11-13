// The Network step of the first-run wizard (issue #179): rows of `hs sys net check` and `hs sys net nics` as the view needs them. No Svelte here.
// check rows: item, state (ok|warn|fail), value, fix (- = none). nics rows: name, link (up|down), MAC (- = none), current (yes|no).

export const CHECK_PATH = '/api/sys/net/check';
export const NICS_PATH = '/api/sys/net/nics';
export const ADVICE = 'Reserve this address on your router (a fixed lease for this server), so it keeps the same address.';

const LABELS = { link: 'Cable', wireless: 'Wi-Fi', address: 'Address', route: 'Router', dns: 'Names (DNS)', clock: 'Clock' };
const TONE = { ok: 'ok', warn: 'warn', fail: 'bad' };
const dash = (v) => (v && v !== '-' ? v : '');

// one view row per check row; an unknown state is shown as a failure, never as fine
export const viewRows = (rows) => (rows || []).map((r) => ({
  item: r[0], label: LABELS[r[0]] || r[0], state: r[1], tone: TONE[r[1]] || 'bad', value: dash(r[2]), fix: dash(r[3]),
}));

// the first failing row (the one to fix first), or null
export const firstFailure = (rows) => viewRows(rows).find((r) => r.tone === 'bad') || null;

// the setup may go on: there are rows and none failed (warnings only warn)
export const passed = (rows) => (rows || []).length > 0 && !firstFailure(rows);

// the address row of a passed check: the one the advice is about, '' otherwise
export const adviceFor = (rows) => (passed(rows) ? viewRows(rows).find((r) => r.item === 'address')?.value || '' : '');

// the cards: current first, then by name (the read already sorts this way; kept here so the view does not depend on it)
export const cards = (rows) => (rows || []).map((r) => ({ name: r[0], up: r[1] === 'up', mac: dash(r[2]), current: r[3] === 'yes' }))
  .sort((a, b) => Number(b.current) - Number(a.current) || a.name.localeCompare(b.name));

// options of the card choice: value, label with the link state
export const nicOptions = (rows) => cards(rows).map((c) => ({ value: c.name, label: `${c.name} (${c.up ? 'cable connected' : 'no cable'})` }));

// the card the choice starts with: the current one, else the first one with a cable, else the first
export const defaultNic = (rows) => { const c = cards(rows); return (c.find((x) => x.current) || c.find((x) => x.up) || c[0])?.name || ''; };
