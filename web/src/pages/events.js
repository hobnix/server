// The Events page, as plain functions (tests/web-events.mjs runs them with node): the rows of `hs sys event list`, the readable text of a kind, the filters.
// A row of the tsv answer: id, time (epoch seconds), source, kind, subject, level, text, payload (JSON or -); `-` = empty. A row of the live stream
// (`domain`) is an object with the same names. Rendered as plain text only, never as HTML.

const empty = (v) => (v == null || v === '-' ? '' : String(v));

export function parseRow(r) {
  if (Array.isArray(r)) {
    const [id, time, source, kind, subject, level, text, payload] = r;
    return norm({ id, time, source, kind, subject, level, text, payload });
  }
  return norm(r || {});
}

function norm(o) {
  let payload = o.payload;
  if (typeof payload === 'string') { try { payload = payload === '-' || payload === '' ? null : JSON.parse(payload); } catch { payload = null; } }
  const level = ['info', 'warn', 'error'].includes(o.level) ? o.level : 'info';
  return { id: Number(o.id) || 0, time: Number(o.time) || 0, source: empty(o.source), kind: empty(o.kind), subject: empty(o.subject), level, text: empty(o.text), payload };
}

// Readable sentences by kind. {s} = subject, {x} = the exit code of the payload, {a} = the actor. Kinds that are not here show the stored text, else their raw name (source.kind).
const KINDS = {
  'job.queued': ['Job {s} was queued', 'Auftrag {s} wurde eingereiht'],
  'job.running': ['Job {s} started', 'Auftrag {s} wurde gestartet'],
  'job.ok': ['Job {s} finished', 'Auftrag {s} ist fertig'],
  'job.failed': ['Job {s} failed (exit {x})', 'Auftrag {s} ist fehlgeschlagen (Exit {x})'],
  'job.cancelled': ['Job {s} was stopped', 'Auftrag {s} wurde gestoppt'],
  'job.interrupted': ['Job {s} did not finish (the server restarted)', 'Auftrag {s} wurde nicht fertig (der Server wurde neu gestartet)'],
  'notify.sent': ['Message sent to {s}', 'Nachricht an {s} gesendet'],
  'notify.held': ['Message held back ({s})', 'Nachricht zurückgehalten ({s})'],
  'notify.failed': ['Message to {s} could not be sent', 'Nachricht an {s} konnte nicht gesendet werden'],
  'disk.plugged': ['Disk {s} was plugged in', 'Festplatte {s} wurde angesteckt'],
  'disk.removed': ['Disk {s} was taken out', 'Festplatte {s} wurde entfernt'],
  'audit.ok': ['{a} ran “{s}”', '{a} hat „{s}“ ausgeführt'],
  'audit.failed': ['{a} ran “{s}”, it failed (exit {x})', '{a} hat „{s}“ ausgeführt, es ist fehlgeschlagen (Exit {x})'],
};

// -> the sentence in `lang` ('en' | 'de'), or the stored text, or the raw name when nothing is known
export function eventText(e, lang = 'en') {
  const t = KINDS[`${e.source}.${e.kind}`];
  if (!t) return e.text || `${e.source}.${e.kind}`;
  const p = e.payload && typeof e.payload === 'object' ? e.payload : {};
  const fill = { s: e.subject || '?', x: p.exit ?? '?', a: p.actor || '?' };
  let out = t[lang === 'de' ? 1 : 0].replace(/\{([sxa])\}/g, (_, k) => String(fill[k]));
  // the reason a message was not sent stays visible (notify.failed text: "<title>: <why>")
  if (e.source === 'notify' && e.kind === 'failed' && e.text) out += `: ${e.text}`;
  return out;
}

// Merge newer rows (live stream or a read) into the list: by id, newest first, no duplicates, at most `max` rows.
export function merge(list, rows, max = 1000) {
  const seen = new Map();
  for (const r of [...rows, ...list]) if (r.id && !seen.has(r.id)) seen.set(r.id, r);
  return [...seen.values()].sort((a, b) => b.id - a.id).slice(0, max);
}

// Filters: level ('' = all, else exactly), kind (substring of "source.kind", case-insensitive), since (epoch seconds, 0 = any)
export function filterRows(list, { level = '', kind = '', since = 0 } = {}) {
  const k = kind.trim().toLowerCase();
  return list.filter((e) => (!level || e.level === level) && (!since || e.time >= since) && (!k || `${e.source}.${e.kind}`.toLowerCase().includes(k)));
}

// The time choices: seconds back from now
export const SINCE = [['', 'Any time', 0], ['1h', 'Last hour', 3600], ['24h', 'Last 24 hours', 86400], ['7d', 'Last 7 days', 604800]];
export const sinceFrom = (key, now = Date.now()) => { const s = SINCE.find((x) => x[0] === key); return s && s[2] ? Math.floor(now / 1000) - s[2] : 0; };
