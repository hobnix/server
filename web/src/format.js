export function bytes(n) {
  if (n == null || isNaN(n)) return '–';
  const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  let v = Number(n);
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${u[i]}`;
}

export function pct(v) {
  return v == null || isNaN(v) ? '–' : `${Math.round(v)}`;
}

export function duration(s) {
  if (s == null || isNaN(s)) return '–';
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d) return `${d} d ${h} h`;
  if (h) return `${h} h ${m} min`;
  return `${m} min`;
}

export function ago(s) {
  if (s == null || isNaN(s)) return '–';
  if (s < 3600) return 'less than an hour ago';
  const h = Math.floor(s / 3600);
  return h < 48 ? `${h} hours ago` : `${Math.floor(h / 24)} days ago`;
}

// A time the server sends as epoch seconds ("-" or nothing = never) -> "5 min ago", "3 h ago", "2 d ago"; `now` is in milliseconds (for tests).
export function agoShort(epoch, now = Date.now()) {
  const t = Number(epoch);
  if (!epoch || epoch === '-' || isNaN(t) || t <= 0) return '';
  const s = Math.max(0, Math.floor(now / 1000 - t));
  if (s < 90) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 48 * 3600) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
}

// the disk health words of `sys monitor disks` -> a status dot
export function healthDot(h) {
  const t = (h || '').toUpperCase();
  if (!t || t === '-') return 'off';
  if (/BAD|FAIL/.test(t)) return 'bad';
  if (/WATCH|WARN/.test(t)) return 'warn';
  return 'ok';
}

// "512MiB", "2GiB", "1.5 TB" -> bytes (NaN when it is not a size); for sorting a column of sizes that the server sends as text
export function sizeToBytes(t) {
  const m = String(t ?? '').trim().match(/^([0-9.]+)\s*([KMGT]?)(i?B?)$/i);
  if (!m) return NaN;
  const unit = { '': 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 }[m[2].toUpperCase()];
  return Number(m[1]) * unit;
}
