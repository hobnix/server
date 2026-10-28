// What a page reads first, by address (pure: tests/web-prefetch.mjs checks every path against the READS allowlist of scripts/web-serve.py).
const A = '/api/sys/';
const DISKS = [`${A}monitor/disks`, `${A}disk-health/list`, `${A}state/disks`, `${A}disk/marks`, `${A}pool/members?pool=bulk`];
const SHARES = [`${A}shares/overview`, `${A}shares/deleted`, `${A}ct/list`];
const pool = (p) => [`${A}pool/info?pool=${p}`, `${A}pool/members?pool=${p}`, `${A}monitor/disks`, `${A}disk/marks`];

// The address may carry its node and a query (/node/homeserver/storage/bulk/disks?x=1); the table below is keyed by the INNER path.
export const innerPath = (p) => (p || '').replace(/^\/node\/[^/]+(?=\/|$)/, '').replace(/[?#].*$/, '') || '/';

export function readsFor(path) {
  path = innerPath(path);
  let m;
  if ((m = path.match(/^\/storage\/pools\/([a-z0-9-]+)$/))) return pool(m[1]);
  // the old addresses (redirected) keep their keys
  if ((m = path.match(/^\/storage\/(bulk|fast)$/))) return pool(m[1]);
  if ((m = path.match(/^\/storage\/(bulk|fast)\/disks$/))) return DISKS;
  if ((m = path.match(/^\/storage\/(bulk|fast)\/shares$/))) return SHARES;
  switch (path) {
    case '/': return [`${A}status`, `${A}monitor/disks`, `${A}setup/list`, `${A}ups/status`];
    case '/instances': return [`${A}ct/list`, `${A}backup/overview`, `${A}services/list`, `${A}recipes/list`];
    case '/network': return [`${A}ct/list`, `${A}dns/list`, `${A}ports/list`, `${A}remote/list`, `${A}unifi/clients`, `${A}unifi/networks`];
    case '/identity/users': case '/identity/groups': return [`${A}users/list`, `${A}users/groups`];
    case '/identity/certificates': return [`${A}dc/state`];
    case '/monitoring/hardware': return [`${A}hardware`, `${A}monitor/disks`, `${A}ups/status`];
    case '/extensions/games': return [`${A}ext/games/list`, `${A}ext/games/state`];
    case '/protection/backup': return [`${A}backup/state`, `${A}backup/overview`, `${A}backup/snapshots?tag=shares`, `${A}backup/snapshots?tag=host`];
    case '/protection/snapshots': return SHARES;
    case '/protection/expiry': return [`${A}expiry/list`];
    case '/operations/health': return [`${A}health/next`, `${A}health/list`, `${A}jobs/list`, `${A}status`];
    case '/instances/apps': case '/operations/apps': return [`${A}recipes/list`, `${A}ct/list`];
    case '/instances/services': case '/operations/services': return [`${A}services/list`, `${A}services/routes`, `${A}ct/list`];
    case '/extensions/posters': return [`${A}ext/posters/list`];
    case '/operations/notifications': return [`${A}notify/channels`, `${A}notify/providers`];
    case '/monitoring/diagnostics': return [`${A}reads/status`];
    case '/storage/encryption': return [`${A}encryption/list`, `${A}status`];
    case '/storage/vault': return [`${A}status`, `${A}vault/list`, `${A}vault/usage`, `${A}vault/uses`];
    case '/storage/pools': return [`${A}pool/info?pool=bulk`, `${A}pool/info?pool=fast`, `${A}monitor/disks`];
    case '/storage/disks': case '/storage/unassigned': return DISKS;
    case '/storage/shares': return SHARES;
    case '/storage/files': return [`${A}fm/locations`];
    case '/settings': return [`${A}config/list`];
    case '/setup': return [`${A}setup/list`];
    case '/nodes': return [`${A}node/list`];
    default: return [];
  }
}

