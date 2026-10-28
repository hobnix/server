// helpers shared by the storage pages
export const poolOf = (path) => (/\/storage\/fast/.test(path) ? 'fast' : 'bulk');

// `pool info` lines: "key: value" facts, then free lines (the mirror tree or the SnapRAID disk lines)
export function parseInfo(rowList) {
  const facts = {};
  const rest = [];
  for (const r of rowList) {
    const line = (r[0] ?? '').trim();
    const m = /^([A-Za-z ]+):\s*(.*)$/.exec(line);
    if (m && !(m[1].toLowerCase() in facts)) facts[m[1].toLowerCase()] = m[2];
    else if (line) rest.push(line);
  }
  return { facts, rest };
}

// "1.2T (41%)" style sizes from df/zpool are text already; just pull the percentage out
export const percentOf = (s) => {
  const m = /\((\d+)%\)/.exec(s || '');
  return m ? Number(m[1]) : null;
};

// which pool a `monitor disks` role belongs to: ZFS members carry the pool name, SnapRAID disks "bulk data-01"
export function diskPool(role) {
  if (/^bulk/.test(role)) return 'bulk';
  if (['system', 'free', 'mounted'].includes(role) || /^backup/.test(role)) return '';
  return role;
}

// status colours of the design (same values as the --st-* tokens)
export const DOT = { ok: 'var(--st-ok)', warn: 'var(--st-warn)', bad: 'var(--st-bad)', off: 'var(--st-off)' };

// "4.0 TB" -> "4 TB" like the design
export const sizeTxt = (b) => {
  if (b == null || isNaN(b) || b <= 0) return '–';
  const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  let v = Number(b);
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1).replace(/\.0$/, '')} ${u[i]}`;
};

// "2.00 / 4.00 TB" (used / size, like the pool card); only the size while the free space is unknown ("-" or empty)
export const spaceTxt = (free, total) => {
  const t = Number(total);
  if (free == null || free === '' || free === '-' || isNaN(Number(free)) || !(t > 0)) return sizeTxt(t);
  const u = t >= 1e12 ? 1e12 : 1e9;
  return `${(Math.max(0, t - Number(free)) / u).toFixed(2)} / ${(t / u).toFixed(2)} ${u === 1e12 ? 'TB' : 'GB'}`;
};

// "220 GB" / "1.2TB" -> bytes (0 when it is not a size)
export function parseSize(s) {
  const m = /^([\d.]+)\s*([KMGTP]?)B?$/i.exec((s ?? '').trim());
  if (!m) return 0;
  return Number(m[1]) * 1000 ** ('KMGTP'.indexOf(m[2].toUpperCase()) + 1);
}

// 21412 -> "21 412 h"
export const hoursTxt = (h) => (h && h !== '-' && !isNaN(h) ? `${Math.round(Number(h)).toString().replace(/\B(?=(\d{3})+$)/g, ' ')} h` : '–');

// the role column of the disks list: "bulk data-01" -> "data · bulk", "fast" -> "fast", "mounted" -> "other"
export function roleLabel(role) {
  const m = /^bulk (data|parity)-\d+$/.exec(role ?? '');
  if (m) return role.replace(/^bulk /, '');
  if (role === 'mounted') return 'other';
  return role ?? '';
}

export const dateOf = (epoch) => (Number(epoch) > 0 ? new Date(Number(epoch) * 1000).toLocaleDateString('sv-SE') : '');

// the serial is the last word of the model+serial column; a by-id name contains it
export function serialIn(model, id) {
  const s = (model ?? '').trim().split(/\s+/).pop();
  return !!s && s.length > 3 && id.includes(s);
}
