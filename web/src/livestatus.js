// Parse the rows of `hs sys live status` for the Diagnostics page.
// Pure JavaScript: no fetch, no Redis, no Svelte, no CLI contract changes.

// topic, interval, age (-1 = none), generation, exit code, error, error timestamp; seven fields, eight since #153 (needs), nine with the status (#322)
/**
 * @param {import('./api/sys.gen').SysLines<'live.status'>} rows
 * @param {number} [nowSec]
 */
export function parseLiveRows(rows, nowSec) {
  const now = nowSec ?? Date.now() / 1000;
  return (rows || [])
    .filter((r) => Array.isArray(r) && r.length >= 7)
    .map(([topic, everyStr, ageStr, genStr, rcStr, errStr, tsErrStr, needsStr, statusStr]) => {
      const every = Number(everyStr);
      const age = ageStr === '-1' ? null : Number(ageStr);
      const gen = Number(genStr) || 0;
      const rc = rcStr === '-' ? null : Number(rcStr);
      const err = errStr === '-' ? null : errStr;
      const tsErr = tsErrStr === '-' ? null : Number(tsErrStr);
      const needs = !needsStr || needsStr === '-' ? [] : needsStr.split(',');
      const storedTs = age !== null ? now - age : null;

      let state = 'fresh';
      if (age === null) {
        state = err ? 'never' : 'pending';
      } else if (statusStr === 'expired' || statusStr === 'error' || (!statusStr && age > 3 * every)) {
        state = 'stale';
      } else if ((rc !== null && rc !== 0) || (err && tsErr !== null && tsErr > storedTs)) {
        state = 'failing';
      }
      return { topic, every, age, gen, rc, err, tsErr, state, needs };
    });
}

// The Live state page: the named-key document of `hs sys live inspect` ({now, topics: [...]}). Optional keys (needs, status, ttl, source) are
// only there when the server knows them; `has` says which optional columns to show.
/**
 * @param {any} doc
 * @param {number} [nowSec]
 */
export function parseInspect(doc, nowSec) {
  void nowSec;
  const list = Array.isArray(doc?.topics) ? doc.topics : [];
  const rows = list
    .filter((t) => t && typeof t.topic === 'string')
    .map((t) => {
      const age = typeof t.age === 'number' ? t.age : null;
      const rc = typeof t.rc === 'number' ? t.rc : null;
      const err = t.err ? String(t.err) : null;
      const tsErr = typeof t.ts_err === 'number' ? t.ts_err : null;
      const every = Number(t.interval);
      const storedTs = age !== null && typeof doc.now === 'number' ? doc.now - age : null;
      let state = 'fresh';
      if (typeof t.status === 'string') state = t.status;
      else if (t.cap_on === false) state = 'off';
      else if (age === null) state = err ? 'never' : 'pending';
      else if (age > 3 * every) state = 'stale';
      else if ((rc !== null && rc !== 0) || (err && tsErr !== null && storedTs !== null && tsErr > storedTs)) state = 'failing';
      return { ...t, every, age, rc, err, tsErr, gen: Number(t.gen) || 0, words: Array.isArray(t.words) ? t.words : [],
               groups: Array.isArray(t.groups) ? t.groups : [], state };
    });
  return {
    rows,
    has: {
      needs: rows.some((r) => Array.isArray(r.needs)),
      status: rows.some((r) => typeof r.status === 'string'),
      ttl: rows.some((r) => r.ttl !== undefined && r.ttl !== null),
    },
  };
}
