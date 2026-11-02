// The status tags of Settings (plain functions, tested in tests/web-settings-steps.mjs).

// Where a part stands: off | on | running | rebuild needed. `running` is the state of the row `running` of its status read ('' when unknown).
// A part with a NixOS module that is on but not running yet waits for `hs rebuild`.
export function partTag(part, running) {
  if (!part?.on) return { state: 'off', label: 'off' };
  if (part.nix && running && running !== 'ok') return { state: 'warn', label: 'rebuild needed' };
  if (running === 'ok') return { state: 'ok', label: 'running' };
  return { state: 'ok', label: 'on' };
}

// The tag of the Updates header from the rows of `hs sys system updates` ([key, value]); null while nothing is read yet.
export function updatesTag(rows) {
  if (!Array.isArray(rows) || !rows.length) return null;
  const behind = Number(Object.fromEntries(rows.map((r) => [r[0], r[1]])).behind) || 0;
  return behind > 0
    ? { state: 'warn', label: `${behind} update${behind === 1 ? '' : 's'} available` }
    : { state: 'ok', label: 'up to date' };
}
