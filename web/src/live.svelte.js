// The live stream of the server (/api/events): `changed` says a topic has a new generation, so a poll with that topic reads again at once.
// While the stream is closed or the server says `down` (its state service is lost), live.open is false and the polls use their timers.
// EventSource reconnects by itself.
export const live = $state({ open: false, gen: {}, topics: {} });

// URL -> topic map from the session answer (features.topics): a poll without its own topic argument follows the stream through it.
export function setTopics(map) { live.topics = map && typeof map === 'object' ? map : {}; }

let es = null;

export function startLive() {
  if (es || typeof EventSource === 'undefined') return;
  es = new EventSource('/api/events');
  es.addEventListener('open', () => { live.open = true; });
  es.addEventListener('up', () => { live.open = true; });
  es.addEventListener('down', () => { live.open = false; });
  es.addEventListener('error', () => { live.open = false; });
  es.addEventListener('changed', (ev) => {
    try {
      const m = JSON.parse(ev.data);
      if (m && m.topic) live.gen[m.topic] = m.gen;
    } catch { /* a broken frame is ignored */ }
  });
}

export function stopLive() {
  if (es) es.close();
  es = null;
  live.open = false;
  live.gen = {};
}
