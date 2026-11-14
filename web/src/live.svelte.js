// The live stream of the server (/api/events): `changed` says a topic has a new generation, so a poll with that topic reads again at once.
// While the stream is closed or the server says `down` (its state service is lost), live.open is false and the polls use their timers.
// `domain` is a row of the event log (id = log id; EventSource sends Last-Event-ID on a reconnect, the server replays the rows after it).
// `resync` says rows or changes may be lost (gap too big, queue full): every followed topic is read again.
// `open` = the stream is up. `follow` = the polls may rely on it for the live-state topics (only in mode redis; otherwise those topics never change and the polls keep their timers).
// The domain events (`events`) are served in every mode (ADR 0005), so a page that reads them (the job records) uses `open` alone.
// EventSource reconnects by itself. `beat` (the server sends it when the stream is idle) feeds a watchdog (livewatch.js): a stream that went silent is reopened.
import { LiveWatch } from './livewatch.js';

export const live = $state({ open: false, follow: false, gen: {}, topics: {}, events: [], lastId: 0, resyncs: 0 });
const KEEP = 100;   // domain events kept in live.events

// URL -> topic map from the session answer (features.topics): a poll without its own topic argument follows the stream through it.
export function setTopics(map) { live.topics = map && typeof map === 'object' ? map : {}; }

let es = null, watch = null, timer = null, needResync = false;

// Reads every followed topic again: the polls read live.resyncs next to live.gen[topic], so a new value runs each of them once.
export function resyncAll() { live.resyncs += 1; }

function connect() {
  es = new EventSource('/api/events');
  const seen = (name, fn) => es.addEventListener(name, (ev) => { watch?.frame(); fn(ev); });
  seen('open', () => { live.open = true; if (needResync) { needResync = false; resyncAll(); } });
  seen('up', () => { live.open = true; });
  seen('down', () => { live.open = false; });
  es.addEventListener('error', () => { live.open = false; });
  seen('beat', () => {});
  seen('changed', (ev) => {
    try {
      const m = JSON.parse(ev.data);
      if (m && m.topic) live.gen[m.topic] = m.gen;
    } catch { /* a broken frame is ignored */ }
  });
  seen('domain', (ev) => {
    try {
      const m = JSON.parse(ev.data);
      if (!m || !m.id || m.id <= live.lastId) return;
      live.lastId = m.id;
      live.events = [...live.events, m].slice(-KEEP);
    } catch { /* a broken frame is ignored */ }
  });
  seen('resync', () => { resyncAll(); });
}

function onVisible() { if (!document.hidden) watch?.check(); }

export function startLive() {
  if (es || typeof EventSource === 'undefined') return;
  watch = new LiveWatch({
    now: () => Date.now(),
    reconnect: (secs) => {
      console.warn(`live stream silent for ${secs} s: reconnecting`);
      if (es) es.close();
      live.open = false;
      needResync = true;
      connect();
    },
  });
  connect();
  timer = setInterval(() => watch?.check(), 15000);
  if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVisible);
}

export function stopLive() {
  if (es) es.close();
  es = null;
  if (timer) clearInterval(timer);
  timer = null;
  watch = null;
  needResync = false;
  if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVisible);
  live.open = false;
  live.gen = {};
  live.events = [];
  live.lastId = 0;
}
