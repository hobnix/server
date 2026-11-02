// Which job a button started: the area and arguments of its plan ("routes apply --proxy local"). Plain JS (no runes) so node can test it.
// The tasks list (ui.svelte.js) keeps the key of every job started from this browser; a button asks whether its own job still runs.
export const jobKey = (area, args = []) => [area, ...args].join(' ');

// `args` left out = any job of that area; otherwise exactly that plan (`apply` is not `apply --proxy local`: two buttons, two jobs).
export function jobMatches(key, area, args) {
  if (!key) return false;
  if (args !== undefined) return key === jobKey(area, args);
  return key === area || key.startsWith(area + ' ');
}
