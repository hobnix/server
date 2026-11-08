// The guided Docker wizard on plain data (no Svelte, no DOM; tests/web-docker-editor.mjs runs it with node).
// generate(draft) -> { name, compose, env, notes[] }: the same text a person would write by hand, in the same shape the `docker run` converter
// (dockerrun.js) uses: every variable goes to the .env text and the service reads it with `env_file: .env`; nothing is added that the
// owner did not answer. The editor then opens on exactly this text.
//   draft = { name, image, restart, ports: [{ host, container, proto }], volumes: [{ kind: 'share'|'folder', share, sub, cpath, ro }], env: [{ key, value }] }
import { cq, scalar, envLine, nameFrom } from './dockerrun.js';
import { mountPathOf, joinHost, validContainerPath, validSub, validShareValue, findMount } from './volumes.js';

export const APP_NAME = /^[a-z0-9][a-z0-9_-]{0,40}$/;
export const IMAGE = /^[A-Za-z0-9][A-Za-z0-9._\-/:@]{0,199}$/;
export const ENV_KEY = /^[A-Za-z_][A-Za-z0-9_]*$/;
export const RESTART = ['unless-stopped', 'always', 'on-failure', 'no'];

export const emptyDraft = () => ({ name: '', image: '', restart: 'unless-stopped', ports: [], volumes: [], env: [] });

// the app name the wizard suggests for an image (nginx:alpine -> nginx)
export const suggestName = (image) => (String(image || '').trim() ? nameFrom(String(image).trim()) : '');

const portNum = (v) => /^[0-9]{1,5}$/.test(String(v).trim()) && +v >= 1 && +v <= 65535;

// the problems of one step: [] when it can go on. Step ids: image, ports, storage, env
export function problems(step, d) {
  const out = [];
  if (step === 'image') {
    if (!IMAGE.test(String(d.image).trim())) out.push('Enter an image such as nginx:alpine or ghcr.io/owner/app:1.2.');
    if (!APP_NAME.test(String(d.name).trim())) out.push('The app name is lower case letters, digits, - and _, up to 41 characters.');
  } else if (step === 'ports') {
    const seen = new Set();
    d.ports.forEach((p, i) => {
      if (!portNum(p.host) || !portNum(p.container)) out.push(`Port ${i + 1}: both numbers must be between 1 and 65535.`);
      const k = `${p.host}/${p.proto || 'tcp'}`;
      if (seen.has(k)) out.push(`Port ${i + 1}: ${k} is used twice.`);
      seen.add(k);
    });
  } else if (step === 'storage') {
    d.volumes.forEach((v, i) => {
      if (!validContainerPath(v.cpath)) out.push(`Folder ${i + 1}: the path inside the app starts with / (letters, digits, . _ - /).`);
      if (!validSub(v.sub)) out.push(`Folder ${i + 1}: the subfolder is not valid.`);
      if (v.kind === 'share' && !validShareValue(v.share)) out.push(`Folder ${i + 1}: pick a share.`);
    });
  } else if (step === 'env') {
    const seen = new Set();
    d.env.forEach((e, i) => {
      if (!ENV_KEY.test(String(e.key).trim())) out.push(`Variable ${i + 1}: the name is letters, digits and _, not starting with a digit.`);
      if (seen.has(e.key)) out.push(`Variable ${i + 1}: ${e.key} is set twice.`);
      seen.add(e.key);
      if (/[\r\n]/.test(e.value ?? '')) out.push(`Variable ${i + 1}: a value is one line.`);
    });
  }
  return out;
}

// the source of one volume entry
export function volumeEntry(v, mounts = []) {
  const remote = String(v.share || '').startsWith('remote:');
  const target = remote ? { peer: v.share.slice(7) } : { share: v.share };
  const host = v.kind === 'share'
    ? joinHost(findMount(mounts, target)?.path ?? mountPathOf(remote ? v.share.slice(7) : v.share), v.sub)
    : `./data/${String(v.sub || '').replace(/^\/+|\/+$/g, '') || String(v.cpath).replace(/^\/+|\/+$/g, '').replace(/\//g, '-')}`;
  return `${host}:${String(v.cpath).trim()}${v.ro || (v.share || '').startsWith('remote:') ? ':ro' : ''}`;
}

// what the owner should know before the editor opens (never hidden changes: only remarks about what was asked for)
export function notes(d, mounts = []) {
  const out = [];
  for (const v of d.volumes) {
    if (v.kind === 'share' && v.share && !v.share.startsWith('remote:') && !findMount(mounts, { share: v.share })) {
      out.push(`The share ${v.share} is not given to Docker yet. Apply refuses a volume under /shares/${v.share} until you use Bind share in the editor, which shows the plan.`);
    }
  }
  if (d.env.some((e) => /PASS|TOKEN|SECRET|KEY/i.test(e.key))) out.push('Variables go to the .env text only; the compose file reads them with env_file: .env.');
  return out;
}

export function generate(d, mounts = []) {
  const name = String(d.name).trim();
  const L = ['services:', `  ${name}:`, `    image: ${scalar(String(d.image).trim())}`];
  const list = (key, items) => { if (items.length) { L.push(`    ${key}:`); for (const x of items) L.push(`      - ${cq(x)}`); } };
  list('ports', d.ports.map((p) => `${String(p.host).trim()}:${String(p.container).trim()}${p.proto === 'udp' ? '/udp' : ''}`));
  list('volumes', d.volumes.map((v) => volumeEntry(v, mounts)));
  const envLines = d.env.filter((e) => String(e.key).trim()).map((e) => envLine(String(e.key).trim(), e.value ?? ''));
  if (envLines.length) L.push('    env_file: .env');
  if (d.restart && d.restart !== 'no') L.push(`    restart: ${d.restart}`);
  return { name, compose: L.join('\n') + '\n', env: envLines.length ? envLines.join('\n') + '\n' : '', notes: notes(d, mounts) };
}

// The hand-over to the editor: kept only in memory (the .env text may hold secrets: never in the browser's storage), taken once.
let held = null;
export const setHandoff = (h) => { held = h; };
export function takeHandoff() { const h = held; held = null; return h; }
