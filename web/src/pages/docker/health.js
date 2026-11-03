// The checks of `hs sys docker health` (rows id state fix detail reason): what the Docker page, the tree and the capability page say when
// Docker is on but something it needs is missing (the share apps, its mount). One place, so a banner and a dimmed tree entry never disagree.

export const DOCKER_PATH = '/instances/docker';

// the rows that are not fine: state warn or fail ("off" is a check that does not apply yet)
export function problems(list) {
  return (Array.isArray(list) ? list : [])
    .filter((r) => Array.isArray(r) && r.length >= 5 && (r[1] === 'fail' || r[1] === 'warn'))
    .map((r) => ({ id: r[0], state: r[1], reason: r[4] }));
}

// the tree: a dot on Docker and its children dimmed (they would only fail) while a check fails; { path: { dot, title, dim } }
export function treeMeta(list, children = []) {
  const p = problems(list);
  if (!p.length) return {};
  const title = p.map((x) => x.reason).join(' ');
  const m = { [DOCKER_PATH]: { dot: p.some((x) => x.state === 'fail') ? 'bad' : 'warn', title } };
  for (const c of children) m[c] = { dim: true, title };
  return m;
}

// the paths below the Docker entry of the tree (nav.js), so a new page under Docker is dimmed too without a change here
export function dockerChildren(items) {
  const find = (list) => {
    for (const it of list ?? []) {
      if (it.path === DOCKER_PATH) return it;
      const f = find(it.children);
      if (f) return f;
    }
    return null;
  };
  const all = (it) => (it.children ?? []).flatMap((c) => [c.path, ...all(c)]).filter(Boolean);
  const d = find(items);
  return d ? all(d) : [];
}
