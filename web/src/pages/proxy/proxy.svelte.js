// The proxyserver's status document (kind "proxyserver", schema 1), read through the homeserver's /api/proxy/status.
// Call useProxy() while a component is created (it polls). `state` is 'loading' | 'off' (404: proxyStatusUrl not set) | 'down' (502) | 'ok'.
import { poll } from '../../data.svelte.js';
import { route } from '../../route.svelte.js';
import { VPS_NODE } from '../../redirects.js';

// The document of the node on screen: the proxyserver node (the old vps part) is read over HTTP from proxyStatusUrl; any other edge node over SSH,
// the word status only (`hs sys node status <name>`, node/status in the READS). Both have the same shape (kind "proxyserver").
export function useProxy(ms = 10000) {
  const st = poll(() => (route.node === VPS_NODE || !route.node ? '/api/proxy/status' : `/api/sys/node/status/${encodeURIComponent(route.node)}`), ms);
  const doc = $derived(st.data);
  const state = $derived(doc ? 'ok' : !st.loaded ? 'loading' : st.error?.status === 404 && (route.node === VPS_NODE || !route.node) ? 'off' : 'down');

  // the document holds cpu counters: the load is the difference between two readings
  let prev = null;
  let cpu = $state(null);
  let cpuLive = $state([]);
  $effect(() => {
    const x = st.data;
    if (!x || !x.cpu || (prev && prev.time === x.time)) return;
    if (prev?.cpu) {
      const dt = x.cpu.total - prev.cpu.total, di = x.cpu.idle - prev.cpu.idle;
      if (dt > 0) {
        cpu = Math.max(0, Math.min(100, (1 - di / dt) * 100));
        cpuLive = [...cpuLive, cpu].slice(-40);
      }
    }
    prev = x;
  });

  // the last 24 hours (one median per hour; null = no reading), as plain numbers for a sparkline
  const hours = (key) => (doc?.history?.hours ?? []).map((h) => h?.[key]).filter((v) => v != null && !isNaN(v));

  return {
    st,
    get doc() { return doc; },
    get state() { return state; },
    get error() { return st.error?.message ?? ''; },
    get cpu() { return cpu; },
    get cpuLive() { return cpuLive; },
    hours,
  };
}

// what the document does not carry; the UI says so instead of inventing it
export const KNOWN = ['schema', 'kind', 'host', 'time', 'uptime_s', 'load', 'cpu', 'mem', 'net', 'net_tailscale', 'pools', 'problems', 'tailscale', 'mail_queue', 'failed_units', 'history',
  // optional sections (docs/PLAN-web-backend.md, "The VPS status document"); the pages draw them as cards, not as raw keys
  'mail', 'watcher', 'game_ports', 'ports', 'certificate', 'revision', 'os', 'region', 'tailscale_info', 'settings'];

// a short text for any value an unknown key might hold
export function brief(v) {
  const t = typeof v === 'string' ? v : JSON.stringify(v);
  return t.length > 120 ? `${t.slice(0, 117)}…` : t;
}
