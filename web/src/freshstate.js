// The worst status of the reads on a page (X-HS-Status, #323), for the top bar. Pure: no fetch, no Svelte (tests/web-freshstate.mjs).
const RANK = { fresh: 0, stale: 1, expired: 2, error: 3 };

/**
 * @param {Array<{status: string, topic?: string, error?: string, lastOk?: number} | null | undefined>} states
 * @returns {{status: string, topics: string[], error: string, lastOk: number | null}}
 */
export function worst(states) {
  let status = 'fresh';
  for (const s of states) if (s && (RANK[s.status] ?? 0) > RANK[status]) status = s.status;
  const bad = states.filter((s) => s && s.status === status && status !== 'fresh');
  const lastOks = bad.map((s) => s.lastOk).filter((x) => typeof x === 'number');
  return {
    status,
    topics: [...new Set(bad.map((s) => s.topic).filter(Boolean))],
    error: bad.map((s) => s.error).find(Boolean) || '',
    lastOk: lastOks.length ? Math.min(...lastOks) : null,
  };
}
