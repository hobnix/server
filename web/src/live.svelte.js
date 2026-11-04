// The live stream of the server (/api/events): `changed` says a topic has a new generation, so a poll with that topic reads again at once.
// While the stream is closed or the server says `down` (its state service is lost), live.open is false and the polls use their timers.
// `domain` is a row of the event log (id = log id; EventSource sends Last-Event-ID on a reconnect, the server replays the rows after it).
// `resync` says rows or changes may be lost (gap too big, queue full): every followed topic is read again.
// EventSource reconnects by itself.
export const live = $state({ open: false, gen: {}, topics: {}, events: [], lastId: 0, resyncs: 0 });
const KEEP = 100;   // domain events kept in live.events

// URL -> topic map from the session answer (features.topics): a poll without its own topic argument follows the stream through it.
export function setTopics(map) { live.topics = map && typeof map === 'object' ? map : {}; }

let es = null;

// Reads every followed topic again: the polls read live.resyncs next to live.gen[topic], so a new value runs each of them once.
export function resyncAll() { live.resyncs += 1; }

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
  es.addEventListener('domain', (ev) => {
    try {
      const m = JSON.parse(ev.data);
      if (!m || !m.id || m.id <= live.lastId) return;
      live.lastId = m.id;
      live.events = [...live.events, m].slice(-KEEP);
    } catch { /* a broken frame is ignored */ }
  });
  es.addEventListener('resync', () => { resyncAll(); });
}

export function stopLive() {
  if (es) es.close();
  es = null;
  live.open = false;
  live.gen = {};
  live.events = [];
  live.lastId = 0;
}
