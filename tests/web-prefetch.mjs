// The pages' first reads (web/src/readsfor.js) must all be allowlisted reads of the web server (READS in scripts/web-serve.py), or the prefetch asks for nothing.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { readsFor } from '../web/src/readsfor.js';

let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };

const src = readFileSync(new URL('../scripts/web-serve.py', import.meta.url), 'utf8');
const reads = src.slice(src.indexOf('READS = {'), src.indexOf('\nCHANGES = {') > 0 ? src.indexOf('\nCHANGES = {') : undefined);
const known = new Set([...reads.matchAll(/^\s*\("([^"]+)"(?:,\s*"([^"]+)")?,?\):\s*\{/gm)].map((m) => [m[1], m[2]].filter(Boolean).join('/')));
// the reads of the extension packages are declared in their manifests ([[web.reads]] words = "list" -> ext/<name>/list), registered while the package is on
const capDir = new URL('../capabilities/', import.meta.url);
for (const name of readdirSync(capDir)) {
  const f = new URL(`../capabilities/${name}/capability.toml`, import.meta.url);
  if (!existsSync(f)) continue;
  for (const m of readFileSync(f, 'utf8').matchAll(/\[\[web\.reads\]\][^\[]*?^words\s*=\s*"([^"]+)"/gms)) known.add(['ext', name, ...m[1].split(' ')].join('/'));
}
check('the allowlist was read', known.size > 50 && known.has('ct/list') && known.has('status'), String(known.size));

const routes = ['/', '/instances', '/network', '/identity/users', '/identity/groups', '/identity/certificates', '/monitoring/hardware', '/extensions/games', '/protection/backup', '/storage/pools', '/storage/pools/bulk', '/storage/pools/fast', '/storage/disks', '/storage/shares', '/storage/files',
  '/protection/expiry', '/operations/health', '/operations/apps', '/operations/services', '/instances/apps', '/instances/services', '/extensions/posters', '/storage/encryption', '/storage/vault', '/storage/unassigned',
  '/settings', '/setup', '/nodes', '/storage/bulk', '/storage/fast', '/storage/bulk/disks', '/storage/fast/disks', '/storage/bulk/shares'];
const missing = [];
let total = 0;
for (const r of routes) {
  const paths = readsFor(r);
  if (!paths.length) missing.push(`${r}: nothing`);
  for (const p of paths) {
    total++;
    const m = p.match(/^\/api\/sys\/([^?]+)/);
    // the words of the read: the path up to a segment that is an argument (none of these pages prefetches one)
    if (!m || !known.has(m[1])) missing.push(`${r}: ${p}`);
  }
}
check(`every one of the ${total} prefetched paths is an allowlisted read`, missing.length === 0, '\n    ' + missing.join('\n    '));
check('an unknown page prefetches nothing', readsFor('/nowhere').length === 0);
check('the new pool address names its pool', readsFor('/node/hs/storage/pools/fast').some((p) => p.endsWith('pool=fast')) && readsFor('/storage/pools/bulk').some((p) => p.endsWith('pool=bulk')));
check('a pool page names its pool', readsFor('/storage/fast').some((p) => p.endsWith('pool=fast')) && readsFor('/storage/bulk').some((p) => p.endsWith('pool=bulk')));

console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
