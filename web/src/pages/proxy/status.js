// What the proxyserver pages read from the VPS status document, in one place: the tree dots (Shell.svelte) and the cards (Proxy.svelte)
// use the same functions, so a dot and its card never disagree. Every key is optional: a section whose keys are missing is 'off' (grey dot,
// "not available yet" on the card). The exact keys are listed in docs/PLAN-web-backend.md ("The VPS status document").
// Each function returns { dot: 'ok'|'warn'|'bad'|'off', text, title } and never throws on a document of the wrong shape.

const num = (v) => (typeof v === 'number' && isFinite(v) ? v : null);
const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : null);
const arr = (v) => (Array.isArray(v) ? v : []);

// the mail entry: mail.queue (older documents: mail_queue), mail.oldest_s, mail.stalwart (bool), mail.spf ('pass'|'fail'|...), mail.last_delivery (epoch s)
export function mail(d) {
  const m = obj(d?.mail) ?? {};
  const queue = num(m.queue) ?? num(d?.mail_queue);
  const oldest = num(m.oldest_s);
  const stalwart = typeof m.stalwart === 'boolean' ? m.stalwart : null;
  const spf = typeof m.spf === 'string' ? m.spf : null;
  if (queue == null && stalwart == null && spf == null) return { dot: 'off', text: '', title: 'Mail entry: not available', queue, oldest, stalwart, spf, last: num(m.last_delivery) };
  let dot = 'ok', why = 'delivering';
  if (stalwart === false) { dot = 'bad'; why = 'stalwart does not answer'; }
  else if (oldest != null && oldest > 3600) { dot = 'warn'; why = 'a message has waited over an hour'; }
  else if (spf != null && spf !== 'pass') { dot = 'warn'; why = `SPF: ${spf}`; }
  else if (queue != null && queue > 0) why = `${queue} in the queue`;
  return { dot, text: queue ? String(queue) : '', title: `Mail entry: ${why}`, queue, oldest, stalwart, spf, last: num(m.last_delivery) };
}

// the outside watcher: watcher.state ('ok'|'alert'|'stale'), watcher.heartbeat_age_s, watcher.sites [{name, url, code, since}]
export function watcher(d) {
  const w = obj(d?.watcher);
  if (!w) return { dot: 'off', text: '', title: 'Outside watcher: not available', state: null, age: null, sites: [] };
  const sites = arr(w.sites).filter(obj);
  // like the watcher itself (hs-watch.sh): no answer or a 5xx is a problem, any other answer (also 403, 404) means reachable
  const down = sites.filter((s) => !(num(s.code) >= 100 && num(s.code) < 500)).length;
  const age = num(w.heartbeat_age_s);
  let dot = 'ok', why = 'all watched sites answer';
  if (w.state === 'alert' || down > 0) { dot = 'bad'; why = down ? `${down} watched site${down === 1 ? '' : 's'} not answering` : 'the watcher is in alert'; }
  else if (w.state === 'stale' || (age != null && age > 900)) { dot = 'warn'; why = 'the heartbeat is old'; }
  return { dot, text: '', title: `Outside watcher: ${why}`, state: typeof w.state === 'string' ? w.state : null, age, sites, down };
}

// every port the VPS forwards or opens itself: ports.groups [{id: 'games'|'rtc'|'mail'|'own', name, target, probe: {ok, ms}|null,
// rows: [{name, proto, ports, count, forwarded}]}]. For games and rtc `forwarded` means "forwarded to the target", for mail and own "open on
// the VPS itself"; null = unknown. Dot: a probe that fails = bad, a configured port that is not forwarded/open = warn, nothing known = off.
export function ports(d) {
  const p = obj(d?.ports);
  const empty = { dot: 'off', text: '', title: 'Ports: not available', groups: [], forwardedPorts: 0, targets: 0, openPorts: 0 };
  if (!p || !Array.isArray(p.groups)) return empty;
  const groups = arr(p.groups).filter(obj).map((g) => {
    const rows = arr(g.rows).filter(obj).map((r) => ({
      name: typeof r.name === 'string' ? r.name : '', proto: typeof r.proto === 'string' ? r.proto : '', ports: r.ports == null ? '' : String(r.ports),
      count: num(r.count), forwarded: typeof r.forwarded === 'boolean' ? r.forwarded : null,
    }));
    const pr = obj(g.probe);
    return {
      id: typeof g.id === 'string' ? g.id : '', name: typeof g.name === 'string' ? g.name : String(g.id ?? ''), target: typeof g.target === 'string' ? g.target : null,
      probe: pr ? { ok: pr.ok !== false, ms: num(pr.ms) } : null, rows,
      total: rows.reduce((n, r) => n + (r.count ?? 0), 0),
      // the group's own verdict: probe failing = bad, a row not forwarded = warn, any known row/probe = ok, else unknown
      dot: pr && pr.ok === false ? 'bad' : rows.some((r) => r.forwarded === false) ? 'warn' : rows.some((r) => r.forwarded === true) || pr ? 'ok' : 'off',
    };
  });
  if (!groups.length) return empty;
  const through = (g) => g.id === 'games' || g.id === 'rtc';
  const sum = (g) => g.rows.filter((r) => r.forwarded === true).reduce((m, r) => m + (r.count ?? 0), 0);
  const fwd = groups.filter(through).filter((g) => sum(g) > 0);
  const forwardedPorts = fwd.reduce((n, g) => n + sum(g), 0);
  const targets = new Set(fwd.map((g) => g.target).filter(Boolean)).size;
  const openPorts = groups.filter((g) => !through(g)).reduce((n, g) => n + sum(g), 0);
  const dots = groups.map((g) => g.dot);
  const dot = dots.includes('bad') ? 'bad' : dots.includes('warn') ? 'warn' : dots.includes('ok') ? 'ok' : 'off';
  const why = dot === 'bad' ? 'a probe fails' : dot === 'warn' ? 'a configured port is not forwarded or open' : dot === 'ok' ? `${forwardedPorts} port${forwardedPorts === 1 ? '' : 's'} forwarded` : 'nothing could be read';
  return { dot, text: forwardedPorts ? String(forwardedPorts) : '', title: `Ports: ${why}`, groups, forwardedPorts, targets, openPorts };
}

// the certificate: certificate.days_left, certificate.domain (and the config revision: revision.hash / revision.subject, os, region)
export function certificate(d) {
  const c = obj(d?.certificate);
  const days = num(c?.days_left);
  if (days == null) return { dot: 'off', text: '', title: 'Certificate: not available', days: null, domain: null };
  const dot = days < 7 ? 'bad' : days < 21 ? 'warn' : 'ok';
  return { dot, text: `${Math.round(days)} d`, title: `Certificate: ${Math.round(days)} days left`, days, domain: typeof c.domain === 'string' ? c.domain : null };
}

// the dot of the node row: unreachable = bad, an old document or problems = warn
export function node(state, d) {
  if (state === 'down') return { dot: 'bad', title: 'proxyserver is not reachable' };
  if (state !== 'ok') return null;
  const age = d?.time ? Date.now() / 1000 - d.time : 0;
  if (age > 300) return { dot: 'warn', title: 'the status document is old' };
  if (num(d?.problems) > 0) return { dot: 'warn', title: `${d.problems} problem${d.problems === 1 ? '' : 's'}` };
  return { dot: 'ok', title: 'online' };
}

// the tree meta of the proxyserver rows: path -> { dot, title } (same shape as the local rows); none while the page is not configured
export function treeMeta(state, d) {
  const n = node(state, d);
  const m = {};
  if (n) m['/'] = n;
  if (state === 'ok') {
    m['/mail'] = mail(d);
    m['/ports'] = ports(d);
    m['/watcher'] = watcher(d);
    m['/certificate'] = certificate(d);
    const ts = d?.tailscale;
    if (typeof ts === 'string') m['/tailscale'] = { dot: ts === 'Running' ? 'ok' : 'warn', title: `Tailscale: ${ts}` };
  }
  return m;
}

// the node count of the header: this server plus the proxyserver when it answers
export const nodeCount = (state) => (state === 'ok' ? 2 : 1);

// tailscale details for the Tailscale page: tailscale_info {address, tag, latency_ms, may_reach: [{target, ports}], never_reach: [{target, why}]}
export function tailscaleInfo(d) {
  const t = obj(d?.tailscale_info) ?? {};
  return {
    address: typeof t.address === 'string' ? t.address : null,
    tag: typeof t.tag === 'string' ? t.tag : null,
    latency: num(t.latency_ms),
    mayReach: arr(t.may_reach).filter(obj),
    neverReach: arr(t.never_reach).filter(obj),
  };
}

// the VPS settings (its machine.nix keys, secrets as file paths): settings {key: value}
export const settingsOf = (d) => Object.entries(obj(d?.settings) ?? {});
