// path -> page. One line per page; a page that is not listed shows the placeholder. Pages get `deck` (the shared status document) as a prop.
import Summary from './pages/Summary.svelte';
import Instances from './pages/Instances.svelte';
import Shares from './pages/Shares.svelte';
import Health from './pages/Health.svelte';
import Pools from './pages/Pools.svelte';
import Disks from './pages/Disks.svelte';
import Files from './pages/Files.svelte';
import Encryption from './pages/Encryption.svelte';
import Vault from './pages/Vault.svelte';
import Network from './pages/Network.svelte';
import Groups from './pages/Groups.svelte';
import Users from './pages/Users.svelte';
import Hardware from './pages/Hardware.svelte';
import Backup from './pages/Backup.svelte';
import Settings from './pages/Settings.svelte';
import Setup from './pages/Setup.svelte';
import Expiry from './pages/Expiry.svelte';
import Extension from './pages/Extension.svelte';
import Apps from './pages/Apps.svelte';
import Marketplace from './pages/Marketplace.svelte';
import Services from './pages/Services.svelte';
import Docs from './pages/Docs.svelte';
import Certificates from './pages/Certificates.svelte';
import Notifications from './pages/Notifications.svelte';
import WhatsNew from './pages/WhatsNew.svelte';
import Data from './pages/Data.svelte';
import Section from './pages/Section.svelte';
import Proxy from './pages/Proxy.svelte';
import ProxyPorts from './pages/ProxyPorts.svelte';
import ProxyTailscale from './pages/ProxyTailscale.svelte';
import ProxySettings from './pages/ProxySettings.svelte';
import Nodes from './pages/Nodes.svelte';
import NodeSummary from './shell/NodeSummary.svelte';
import NodeHealth from './pages/nodes/NodeHealth.svelte';
import NodeFacts from './pages/nodes/NodeFacts.svelte';

export const routes = {
  '/': Summary,
  '/instances': Instances,
  '/storage': Section,
  '/identity': Section,
  '/protection': Section,
  '/operations': Section,
  '/monitoring': Section,
  '/storage/pools': Pools,
  '/storage/pools/bulk': Pools,
  '/storage/pools/fast': Pools,
  '/storage/disks': Disks,
  '/storage/shares': Shares,
  '/storage/files': Files,
  '/storage/encryption': Encryption,
  '/storage/vault': Vault,
  '/network': Network,
  '/identity/groups': Groups,
  '/identity/users': Users,
  '/identity/certificates': Certificates,
  '/monitoring/hardware': Hardware,
  '/protection/backup': Backup,
  '/operations/health': Health,
  '/protection/expiry': Expiry,
  '/instances/apps': Apps,
  '/marketplace': Marketplace,
  '/instances/services': Services,
  '/operations/notifications': Notifications,
  '/operations/whats-new': WhatsNew,
  '/monitoring/diagnostics': Data,
  '/docs': Docs,
  '/setup': Setup,
  '/settings': Settings,
  '/nodes': Nodes,
};

// The pages of a REMOTE node, by its kind (the main node uses `routes`). They read the node's status document, never a local read.
// An edge or vps node: the proxyserver pages (Summary is the old /proxy page); a peer: summaries of its document. The address /node/<name>/health is the same for all.
const edgeRoutes = {
  '/': Proxy, '/health': NodeHealth, '/mail': Proxy, '/ports': ProxyPorts, '/watcher': Proxy, '/certificate': Proxy, '/tailscale': ProxyTailscale, '/settings': ProxySettings,
};
const peerRoutes = {
  '/': NodeSummary, '/health': NodeHealth, '/storage': NodeFacts, '/instances': NodeFacts, '/protection/backup': NodeFacts,
};
export const nodeRoutes = { vps: edgeRoutes, edge: edgeRoutes, peer: peerRoutes };

// Old address -> new address (redirects.js, pure so that a test can run it); route.svelte.js applies it.
export { redirect, innerMoves, VPS_NODE } from './redirects.js';

// The page for an INNER path (route.path: the address without /node/<name>): the exact path, or a guide (/docs/<lang>/<slug>).
export function pageFor(path, kind = 'main') {
  if (kind !== 'main') return (nodeRoutes[kind] ?? peerRoutes)[path];
  return routes[path] ?? (path.startsWith('/docs/') ? Docs : path.startsWith('/extensions/') ? Extension : path.startsWith('/storage/pools/') ? Pools : undefined);
}
