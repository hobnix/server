// The only place that talks to the backend. A change always sends the CSRF token of the session.
let csrf = '';

// How old each read was when it arrived (X-HS-Age: the server may show an answer it kept for a while; none = just read), by path.
const ages = new Map();
export const ageOf = (path) => {
  const a = ages.get(path);
  return a ? a.age + (Date.now() - a.at) / 1000 : null;
};

async function call(method, path, body, ageKey) {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (method !== 'GET' && csrf) headers['X-CSRF-Token'] = csrf;
  const r = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: 'same-origin' });
  if (method === 'GET' && r.ok) ages.set(ageKey ?? path, { age: Number(r.headers.get('X-HS-Age') ?? 0) || 0, at: Date.now() });
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
export const plan = (area, args, stdin) => call('POST', '/api/plan', { area, args, ...(stdin ? { stdin } : {}) });
export const start = (area, args, confirm, stdin) => call('POST', '/api/start', { area, args, ...(confirm ? { confirm } : {}), ...(stdin ? { stdin } : {}) });
