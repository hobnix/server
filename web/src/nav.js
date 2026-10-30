// The resource tree (left). `storage: true` = needs the encrypted storage, so it dims while that is locked.
// A page that is not built yet shows a placeholder (shell/Placeholder.svelte) with its title from here.
export const tree = [
  {
    label: 'homeserver', icon: 'hard-drives', path: '/', node: true,
    children: [
      {
        label: 'Storage', icon: 'database', path: '/storage', storage: true,
        children: [
          { label: 'Pools', icon: 'cylinder', path: '/storage/pools', storage: true, children: [
            { label: 'bulk', icon: 'cylinder', path: '/storage/pools/bulk', storage: true },
            { label: 'fast', icon: 'lightning', path: '/storage/pools/fast', storage: true },
          ] },
          { label: 'Disks', icon: 'hard-drive', path: '/storage/disks', storage: true },
          { label: 'Shares', icon: 'folders', path: '/storage/shares', storage: true },
          { label: 'Files', icon: 'folder-open', path: '/storage/files', storage: true },
          { label: 'Encryption', icon: 'lock-key', path: '/storage/encryption' },
          { label: 'Vault', icon: 'vault', path: '/storage/vault' },
        ],
      },
      { label: 'Instances', icon: 'cube', path: '/instances', storage: true, children: [
        { label: 'Apps', icon: 'package', path: '/instances/apps', storage: true },
        { label: 'Services', icon: 'arrows-split', path: '/instances/services', capability: 'reverse-proxy' },
      ] },
      { label: 'Marketplace', icon: 'storefront', path: '/marketplace' },
      { label: 'Network', icon: 'network', path: '/network' },
      { label: 'Identity', icon: 'users-three', path: '/identity', storage: true, capability: 'ad', children: [
        { label: 'Groups', icon: 'users-four', path: '/identity/groups', storage: true },
        { label: 'Users', icon: 'user', path: '/identity/users', storage: true },
        { label: 'Certificates', icon: 'certificate', path: '/identity/certificates', storage: true },
      ] },
      { label: 'Monitoring', icon: 'gauge', path: '/monitoring', children: [
        { label: 'Hardware', icon: 'cpu', path: '/monitoring/hardware' },
        { label: 'Diagnostics', icon: 'stethoscope', path: '/monitoring/diagnostics' },
      ] },
      { label: 'Protection', icon: 'shield', path: '/protection', children: [
        { label: 'Backup', icon: 'cloud-arrow-up', path: '/protection/backup' },
        { label: 'Expiry dates', icon: 'calendar-x', path: '/protection/expiry' },
      ] },
      { label: 'Operations', icon: 'gear-six', path: '/operations', children: [
        { label: 'Health', icon: 'heartbeat', path: '/operations/health' },
        { label: 'Notifications', icon: 'bell', path: '/operations/notifications', capability: 'notifications' },
        { label: "What's new", icon: 'sparkle', path: '/operations/whats-new' },
      ] },
      { label: 'Docs', icon: 'book-open', path: '/docs', prefix: true, capability: 'docs' },
      { label: 'Nodes', icon: 'hard-drives', path: '/nodes' },
      { label: 'Setup', icon: 'list-checks', path: '/setup' },
      { label: 'Settings', icon: 'sliders', path: '/settings' },
    ],
  },
  {
    label: 'proxyserver', icon: 'globe-hemisphere-west', path: '/', node: true, gap: true, capability: 'vps',
    children: [
      { label: 'Mail entry', icon: 'envelope-simple', path: '/mail' },
      { label: 'Ports', icon: 'plugs', path: '/ports' },
      { label: 'Outside watcher', icon: 'binoculars', path: '/watcher' },
      { label: 'Certificate', icon: 'certificate', path: '/certificate' },
      { label: 'Tailscale', icon: 'plugs-connected', path: '/tailscale' },
      { label: 'Settings', icon: 'sliders', path: '/settings' },
    ],
  },
];

// The tree without the parts of capabilities that are off (docs/PLAN-modular-core.md step 3). `caps` is the list from the session answer
// (ui.features.capabilities); null/undefined = the server did not say (an older one): show everything. An item with a
// `capability` is shown only while that name is in the list; a page the user opens by its address still works.
export function visible(items, caps) {
  if (!Array.isArray(caps)) return items;
  return items.filter((n) => !n.capability || caps.includes(n.capability));
}

// ── nodes as the roots of the tree ─────────────────────────────────────────────────────────────────
// The paths above are INNER paths: the page of a node is /node/<name><path> (route.svelte.js). The main node (this server) gets the long tree. A
// REMOTE node's tree is built from the capabilities its status document reports (`capabilities`, a list of names): Summary and Health always, then
// `storage` -> Storage, `incus` -> Instances, `backup` -> Backup (all read only, summaries of the document), and for an edge or vps node the
// proxyserver pages (Mail entry, Ports, Outside watcher, Certificate, Tailscale, Settings). `caps` null/undefined = the node did not say: a vps node
// shows all its pages (an old document), any other node only Summary and Health.
export const mainTree = tree[0].children;
const HEALTH = { label: 'Health', icon: 'heartbeat', path: '/health' };
const edgeItems = tree[1].children;
// page -> the edge capability that brings it (a vps node has no list: every page)
const EDGE_NEEDS = { '/mail': 'edge-mail', '/certificate': 'edge-mail', '/ports': 'edge-ports', '/watcher': 'edge-watcher' };
const peerItems = [
  { label: 'Storage', icon: 'database', path: '/storage', capability: 'storage' },
  { label: 'Instances', icon: 'cube', path: '/instances', capability: 'incus' },
  { label: 'Backup', icon: 'cloud-arrow-up', path: '/protection/backup', capability: 'backup' },
];
export const remoteTree = [HEALTH];
export const vpsTree = [HEALTH, ...edgeItems];

// kind: 'main' | 'vps' | 'edge' | 'peer' (hs sys node list); caps: the capability names of the node (main: the session answer, remote: its status document)
export function nodeItems(kind, caps, exts) {
  if (kind === 'main') return [...visible(mainTree, caps), ...extensionItems(exts)];
  if (kind === 'vps' || kind === 'edge') {
    const have = Array.isArray(caps) ? caps : null;
    return [HEALTH, ...edgeItems.filter((i) => kind === 'vps' && !have ? true : !EDGE_NEEDS[i.path] || (have ?? []).includes(EDGE_NEEDS[i.path]))];
  }
  return [HEALTH, ...(Array.isArray(caps) ? peerItems.filter((i) => caps.includes(i.capability)) : [])];
}

// The Extensions group: one page per extension package that is on AND declares a web page (ui.features.extensions, the manifests' [web.page]).
// Nothing is shown while there is no such package. The pages are /extensions/<name> (pages/Extension.svelte renders the declaration).
export function extensionItems(exts) {
  if (!Array.isArray(exts) || !exts.length) return [];
  return [{ label: 'Extensions', icon: 'puzzle-piece', children: exts.map((e) => ({ label: e.title, icon: e.icon || 'puzzle-piece', path: `/extensions/${e.name}` })) }];
}

// the icon of a node root by kind
export const nodeIcon = { main: 'hard-drives', vps: 'globe-hemisphere-west', edge: 'globe-hemisphere-west', peer: 'house-line' };

// the tree item for an inner path (null if none); the shell reads its `storage` and `capability` flags for the page states
export function itemOf(path) {
  const walk = (items) => {
    for (const it of items) {
      if (it.path === path || (it.prefix && path.startsWith(it.path + '/'))) return it;
      if (it.children) { const r = walk(it.children); if (r) return r; }
    }
    return null;
  };
  return walk(tree);
}

export function titleOf(path) {
  const walk = (items, trail) => {
    for (const it of items) {
      const t = [...trail, it.label];
      if (it.path === path) return t;
      if (it.children) { const r = walk(it.children, t); if (r) return r; }
    }
    return null;
  };
  return walk(tree, []);
}
