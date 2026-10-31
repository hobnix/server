// Parse the seven-field rows of `hs sys live status` for the Diagnostics page.
// Pure JavaScript: no fetch, no Redis, no Svelte, no CLI contract changes.

// topic, interval, age (-1 = none), generation, exit code, error, error timestamp
export function parseLiveRows(rows, nowSec) {
  const now = nowSec ?? Date.now() / 1000;
  return (rows || [])
    .filter((r) => Array.isArray(r) && r.length === 7)
    .map(([topic, everyStr, ageStr, genStr, rcStr, errStr, tsErrStr]) => {
      const every = Number(everyStr);
      const age = ageStr === '-1' ? null : Number(ageStr);
      const gen = Number(genStr) || 0;
      const rc = rcStr === '-' ? null : Number(rcStr);
      const err = errStr === '-' ? null : errStr;
      const tsErr = tsErrStr === '-' ? null : Number(tsErrStr);
      const storedTs = age !== null ? now - age : null;

      let state = 'fresh';
      if (age === null) {
        state = err ? 'never' : 'pending';
      } else if (age > 3 * every) {
        state = 'stale';
      } else if ((rc !== null && rc !== 0) || (err && tsErr !== null && tsErr > storedTs)) {
        state = 'failing';
      }
      return { topic, every, age, gen, rc, err, tsErr, state };
    });
}
