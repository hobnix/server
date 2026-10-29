// Polls GET /api/board every 30 s. Not data.svelte.js poll(): its 401 handling would send the kiosk to the sign-in page.
// state: doc (last good answer), error (the server's text of the last failure: a 403/404 says what to switch on), status, loaded.
export function boardPoll(ms = 30000) {
  const s = $state({ doc: null, error: '', status: 0, loaded: false });
  let timer = null;
  let stopped = false;

  async function load() {
    try {
      const r = await fetch('/api/board', { credentials: 'same-origin' });
      let data = null;
      try { data = await r.json(); } catch { /* no body */ }
      if (r.ok) { s.doc = data; s.error = ''; s.status = 200; }
      else {
        s.error = (data && data.error) || `Request failed (${r.status})`;
        s.status = r.status;
        if (r.status === 403 || r.status === 404) s.doc = null;
      }
    } catch {
      s.error = 'The server cannot be reached.';
      s.status = 0;
    }
    s.loaded = true;
    if (!stopped) timer = setTimeout(load, ms);
  }

  load();
  s.stop = () => { stopped = true; clearTimeout(timer); };
  return s;
}
