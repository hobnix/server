// Watchdog of the live stream: an EventSource never hands the `: ping` comment to JavaScript, so a stream that stalled silently (proxy,
// half-open connection) looks open for good. The server sends `event: beat` when idle; this class notes the time of every frame and
// reconnects when none came for `silentMs`. Pure timing logic: the caller gives the clock and the reconnect action.
export class LiveWatch {
  // o: { now(), silentMs = 45000, minGapMs = 10000, reconnect(silentSeconds) }
  constructor(o) {
    this.now = o.now;
    this.silentMs = o.silentMs ?? 45000;
    this.minGapMs = o.minGapMs ?? 10000;
    this.reconnect = o.reconnect;
    this.last = this.now();
    this.lastReconnect = -Infinity;
  }
  // A frame of any kind (open, up, down, changed, domain, resync, beat) arrived.
  frame() { this.last = this.now(); }
  // Called by a timer and when the tab becomes visible; true when it reconnected.
  check() {
    const t = this.now();
    if (t - this.last <= this.silentMs) return false;
    if (t - this.lastReconnect < this.minGapMs) return false;
    const secs = Math.round((t - this.last) / 1000);
    this.lastReconnect = t;
    this.last = t;
    this.reconnect(secs);
    return true;
  }
}
