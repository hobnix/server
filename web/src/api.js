// The only place that talks to the backend. A change always sends the CSRF token of the session.
let csrf = '';

// How old each read was when it arrived (X-HS-Age: the server may show an answer it kept for a while; none = just read), by path.
const ages = new Map();
export const ageOf = (path) => {
  const a = ages.get(path);
  return a ? a.age + (Date.now() - a.at) / 1000 : null;
};

// The status of each read as the server reported it (X-HS-Status: fresh|stale|error|expired; absent = a read that has no live topic), with the topic, the
// error line and the time of the last good read in ms (null = unknown). Read by shell/Fresh.svelte; a page keeps its last data whatever the status is.
const states = new Map();
export const stateOf = (path) => states.get(path) ?? null;

async function call(method, path, body, ageKey, signal) {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (method !== 'GET' && csrf) headers['X-CSRF-Token'] = csrf;
  const r = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: 'same-origin', signal });
  if (method === 'GET' && r.ok) ages.set(ageKey ?? path, { age: Number(r.headers.get('X-HS-Age') ?? 0) || 0, at: Date.now() });
  if (method === 'GET' && r.ok) {
    const st = r.headers.get('X-HS-Status');
    const ok = Number(r.headers.get('X-HS-Last-Ok'));
    if (st) {
      states.set(ageKey ?? path, {
        status: st, topic: r.headers.get('X-HS-Topic') || '', error: r.headers.get('X-HS-Error') || '',
        lastOk: ok > 0 ? ok * 1000 : st === 'fresh' ? Date.now() : Date.now() - (Number(r.headers.get('X-HS-Age') ?? 0) || 0) * 1000,
      });
    } else states.delete(ageKey ?? path);
  }
  let data = null;
  try { data = await r.json(); } catch { /* no body */ }
  if (!r.ok) {
    const e = new Error((data && data.error) || `Request failed (${r.status})`);
    e.status = r.status;
    e.retryAfter = data && data.retry_after;
    throw e;
  }
  return data;
}

// a one-use ticket for the terminal WebSocket; target is 'host' or an instance name
export const terminalTicket = (target) => call('POST', '/api/terminal', { target });

// the last revision of the changelog this user has seen (What's new), kept on the server
export const changesSeen = () => call('GET', '/api/changes/seen');
export const liveRefresh = (topic) => call('POST', '/api/live/refresh', { topic });
export const markChangesSeen = (rev) => call('POST', '/api/changes/seen', { rev });

export const hello = () => call('GET', '/api/hello');

export async function session() {
  try {
    const s = await call('GET', '/api/session');
    csrf = s.csrf;
    return s;
  } catch (e) {
    if (e.status === 401) return null;
    throw e;
  }
}

export async function login(realm, user, password) {
  const s = await call('POST', '/api/login', { realm, user, password });
  csrf = s.csrf;
  return s;
}

export async function logout() {
  await call('POST', '/api/logout', {});
  csrf = '';
}

// A read: /api/sys/<words...>[?query]. 401 means the session ended (the app then shows the sign-in page).
let onAuthLost = () => {};
export const setAuthLostHandler = (fn) => { onAuthLost = fn; };

// a page of text (the guides are Markdown); an error answer is still JSON
export async function getText(path) {
  const r = await fetch(path, { credentials: 'same-origin' });
  if (r.status === 401) onAuthLost();
  if (!r.ok) {
    let data = null;
    try { data = await r.json(); } catch { /* no body */ }
    const e = new Error((data && data.error) || `Request failed (${r.status})`);
    e.status = r.status;
    throw e;
  }
  return r.text();
}

// fresh: the refresh button; the server runs the scripts now instead of answering from what it holds
export async function get(path, fresh = false) {
  try {
    return await call('GET', fresh ? path + (path.includes('?') ? '&' : '?') + 'fresh=1' : path, undefined, path);
  } catch (e) {
    if (e.status === 401) onAuthLost();
    throw e;
  }
}

// A change is always a plan first, then a start (with the typed word when the plan has a confirm_name).
// selection: the file manager's list of item names (the server hands it to the script on stdin, NUL separated)
// document: the docker app-save body (the server serializes it as bytes on stdin)
const planCall = (area, args, stdin, selection, signal, document) => call('POST', '/api/plan', { area, args, ...(stdin ? { stdin } : {}), ...(selection ? { selection } : {}), ...(document !== undefined ? { document } : {}) }, undefined, signal);   // an aborted call rejects with e.name === 'AbortError'

// A plan only reads, so a button can ask for it when the pointer arrives (prefetchPlan) and the dialog that opens a moment later takes the
// answer that is already running or done. Never with stdin, a selection or a document (secrets, file lists); a start forgets everything.
const PLAN_KEEP_MS = 30000;
const planned = new Map();   // "area\0args" -> { at, p }
const planKey = (area, args) => [area, ...args].join('\0');

export function prefetchPlan(area, args) {
  const key = planKey(area, args);
  const hit = planned.get(key);
  if (hit && Date.now() - hit.at < PLAN_KEEP_MS) return hit.p;
  const p = planCall(area, args);
  const entry = { at: Date.now(), p };
  planned.set(key, entry);
  p.catch(() => { if (planned.get(key) === entry) planned.delete(key); });   // a failure is asked again, not kept
  return p;
}

// a call with a signal (the create dialog's live plan: a newer question cancels the older one) is never shared; a document bypasses prefetch
export const plan = (area, args, stdin, selection, signal, document) => (stdin || selection || signal || document !== undefined) ? planCall(area, args, stdin, selection, signal, document) : prefetchPlan(area, args);
export const start = (area, args, confirm, stdin, selection, document) => {
  planned.clear();
  return call('POST', '/api/start', { area, args, ...(confirm ? { confirm } : {}), ...(stdin ? { stdin } : {}), ...(selection ? { selection } : {}), ...(document !== undefined ? { document } : {}) });
};
