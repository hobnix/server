// Helpers for the Docker page and the Instances page: map the 10-field app row and group docker-list rows by parent.
export function appOf(r) {
  if (!Array.isArray(r) || r.length < 10) return null;
  return {
    name: r[0],
    parent: r[1],
    project: r[2],
    state: r[3],
    running: r[4],
    ports: r[5],
    address: r[6],
    images: r[7],
    managed: r[8],
    update: r[9],
  };
}

export function childrenOf(listRows) {
  const map = new Map();
  if (!Array.isArray(listRows)) return map;
  for (const r of listRows) {
    if (!Array.isArray(r) || r.length < 5) continue;
    const parent = r[1];
    if (!parent || parent === '-') continue;
    if (!map.has(parent)) map.set(parent, []);
    map.get(parent).push(r);
  }
  return map;
}
