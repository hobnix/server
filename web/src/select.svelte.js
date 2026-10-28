// A search result (or any link) can ask a list page to preselect an item: setSelection(kind, name) before go(path).
// The page reads it once with takeSelection(kind) inside an $effect (on mount, and again when a new one is set while it is open).
export const pending = $state({ kind: '', name: '' });

export function setSelection(kind, name) {
  pending.kind = kind;
  pending.name = name;
}

// the name waiting for this kind of page, '' if none; it is consumed (a second call gives '')
export function takeSelection(kind) {
  if (pending.kind !== kind || !pending.name) return '';
  const n = pending.name;
  pending.kind = '';
  pending.name = '';
  return n;
}
