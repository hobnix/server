// How a poll waits for its next read. Plain JS so tests/web-live.mjs can load it in node.
// A topic read follows the live stream while it is open (no timer); a 503 with retry_after (state service refreshing) waits that long;
// a failed read and everything else wait the interval it was given.
export function nextDelay(topic, liveOpen, ms, err) {
  if (err && err.status === 503 && Number(err.retryAfter) > 0) return Number(err.retryAfter) * 1000;
  if (err) return ms;   // a failed read tries again on the timer even while live
  if (topic && liveOpen) return null;
  return ms;
}
