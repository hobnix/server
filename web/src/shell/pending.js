// The staged changes: machine.toml changes that wait for one `hs rebuild` (`hs sys rebuild pending`: key, built, now; `-` = not set). Pure, so plain node tests it.
export const pendingItems = (rows) => (rows || []).filter((r) => r && r[0]).map((r) => ({ key: r[0], built: r[1] ?? '-', now: r[2] ?? '-' }));

// "syncEveryHours: 12 -> 6", "gpu: switched on (\"nvidia\")", "gpu: switched off"
export function describe(it) {
  if (it.built === '-') return `${it.key}: set to ${it.now}`;
  if (it.now === '-') return `${it.key}: taken out (was ${it.built})`;
  return `${it.key}: ${it.built} → ${it.now}`;
}

export const headline = (n) => (n === 1 ? '1 change waits for a rebuild' : `${n} changes wait for one rebuild`);
