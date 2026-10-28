// Small pure helpers of the node pages (no Svelte, so a test can run them in node).

// "14 min ago" for a unix time; 'never' without one
export function since(t, now = Date.now() / 1000) {
  if (t == null || isNaN(t)) return 'never';
  const s = Math.max(0, now - t);
  if (s < 90) return 'just now';
  if (s < 5400) return `${Math.round(s / 60)} min ago`;
  if (s < 172800) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}

// the rows of `sys node keyline` (key<TAB>value) as an object: key (ok|locked|missing), user, file, line
export const keyInfo = (rows) => Object.fromEntries((rows ?? []).map((r) => [r[0], r.slice(1).join('\t')]));

// a status document's capabilities as chips, short
export function capList(caps, max = 4) {
  if (!Array.isArray(caps) || !caps.length) return { shown: [], more: 0 };
  return { shown: caps.slice(0, max), more: Math.max(0, caps.length - max) };
}

// the read only summaries of a status document (Storage, Instances, Backup): { pools: [{name, used, size, health}], instances, backup, locked }
export function facts(d) {
  const out = { pools: [], instances: null, backup: null, locked: !!d?.locked };
  for (const [name, p] of Object.entries(d?.pools ?? {})) {
    if (p && typeof p === 'object' && Number(p.size) > 0) out.pools.push({ name, used: Number(p.used) || 0, size: Number(p.size), health: p.health ?? null });
  }
  if (d?.instances && typeof d.instances === 'object') out.instances = { running: Number(d.instances.running) || 0, total: Number(d.instances.total) || 0 };
  if (d?.backup && typeof d.backup === 'object') out.backup = { status: String(d.backup.status ?? ''), age_s: d.backup.age_s == null ? null : Number(d.backup.age_s) };
  return out;
}
