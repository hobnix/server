// The checks of the compose editor on plain data (no CodeMirror, no yaml): cm.js parses the text and passes the object in.
// A finding is { level: 'error' | 'warn', text, path } for a place in the compose object (cm.js maps the path to a range)
// or { level, text, line } for a line (1-based) of the text it was given.
import { unknownKeys } from './schema.js';

// the editor works with LF only (CodeMirror does too); the server refuses a carriage return in the env text
export const normalizeEol = (s) => String(s ?? '').replace(/\r\n?/g, '\n');

const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const APP_RE = /^[a-z0-9][a-z0-9_-]{0,40}$/;

// the host port of a `ports` entry (object with published | "8080:80" | "127.0.0.1:8080:80/tcp"), or null (nothing published, a range, a variable)
export function hostPort(entry) {
  if (entry && typeof entry === 'object') {
    const p = Number(entry.published);
    return Number.isInteger(p) && p > 0 && p < 65536 ? p : null;
  }
  if (typeof entry !== 'string') return null;        // a bare number publishes nothing fixed
  const parts = entry.split('/')[0].split(':');
  if (parts.length < 2) return null;
  const host = parts.length === 2 ? parts[0] : parts[parts.length - 2];
  return /^[0-9]{1,5}$/.test(host) && Number(host) > 0 && Number(host) < 65536 ? Number(host) : null;
}

// live: { schema, isNew, apps: [{ name, ports: "80,443" | "-" }], ct: [names] }; appName: the project name (the name field of a new app)
export function lintCompose(obj, live, appName) {
  const out = [];
  const l = live || {};
  if (l.isNew && appName) {
    if (!APP_RE.test(appName)) out.push({ level: 'error', path: [], text: 'The name must be lower case letters, digits, - or _.' });
    else if ((l.apps || []).some((a) => a.name === appName) || (l.ct || []).includes(appName)) {
      out.push({ level: 'error', path: [], text: `The name ${appName} is taken by an app or an instance.` });
    }
  }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
    out.push({ level: 'error', path: [], text: 'The compose file must be a mapping with a services: section.' });
    return out;
  }
  if (l.schema) for (const path of unknownKeys(l.schema, obj)) out.push({ level: 'warn', path, text: `Unknown key ${path[path.length - 1]}: Docker may ignore or refuse it.` });
  const services = obj.services && typeof obj.services === 'object' ? obj.services : null;
  if (!services) out.push({ level: 'error', path: [], text: 'The compose file needs a services: section.' });
  const owners = new Map();      // host port -> app
  for (const a of l.apps || []) {
    if (a.name === appName || !a.ports || a.ports === '-') continue;
    for (const p of String(a.ports).split(',')) if (/^[0-9]+$/.test(p)) owners.set(Number(p), a.name);
  }
  for (const [sname, svc] of Object.entries(services || {})) {
    if (!svc || typeof svc !== 'object' || !Array.isArray(svc.ports)) continue;
    svc.ports.forEach((entry, i) => {
      const p = hostPort(entry);
      if (p != null && owners.has(p)) out.push({ level: 'error', path: ['services', sname, 'ports', i], text: `Port ${p} is used by ${owners.get(p)}.` });
    });
  }
  return out;
}

// the names a compose text asks for as ${NAME} or ${NAME:?msg} (no default): [{ name, line }]
export function varsUsed(composeText) {
  const out = [];
  String(composeText).split('\n').forEach((raw, i) => {
    const line = raw.replace(/\$\$/g, '').replace(/^\s*#.*$/, '');
    const re = /\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-+?=][^}]*)?\}/g;
    let m;
    while ((m = re.exec(line))) {
      const op = m[2] || '';
      if (op && /^:?[-+=]/.test(op)) continue;      // has a default (or is an alternative): not required
      out.push({ name: m[1], line: i + 1 });
    }
  });
  return out;
}

// the names the env text defines
export function envNames(envText) {
  const names = [];
  for (const line of String(envText).split('\n')) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(line);
    if (m) names.push(m[1]);
  }
  return names;
}

// ${VAR} in the compose text without a default and not in the env text
export function lintVars(composeText, envText) {
  const have = new Set(envNames(envText));
  return varsUsed(composeText).filter((v) => !have.has(v.name)).map((v) => ({ level: 'warn', line: v.line, text: `${v.name} is not set in the .env panel and has no default.` }));
}

export function lintEnv(text) {
  const out = [];
  const seen = new Map();
  String(text).split('\n').forEach((line, i) => {
    if (line === '' || line.startsWith('#')) return;
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(line);
    if (!m) {
      out.push({ level: 'error', line: i + 1, text: `Line ${i + 1} is not NAME=value.` });
      return;
    }
    if (!NAME_RE.test(m[1])) return;
    if (seen.has(m[1])) out.push({ level: 'warn', line: i + 1, text: `${m[1]} is already set in line ${seen.get(m[1])}: the last one wins.` });
    else seen.set(m[1], i + 1);
  });
  return out;
}
