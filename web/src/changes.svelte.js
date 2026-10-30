// What's new, shared: how many changelog entries this user has not seen yet (the tree badge and the Summary banner read it).
// The last seen revision is kept per web user on the server (GET/POST /api/changes/seen), so another browser or a reload agrees.
import { get, changesSeen, markChangesSeen } from './api.js';

export const changes = $state({ seen: '', head: '', count: 0, loaded: false });

// head, mode and entries of a `hs sys changes list` answer: [range, base, head, mode], then [entry, id, date, type, title, docs, body]
export const parseChanges = (data) => {
  const all = data?.rows ?? [];
  const range = all.find((r) => r[0] === 'range');
  return { head: range && range[2] !== '-' ? range[2] : '', mode: range?.[3] ?? '', entries: all.filter((r) => r[0] === 'entry') };
};

export async function load() {
  try {
    changes.seen = (await changesSeen()).rev || '';
    const { head, entries } = parseChanges(await get('/api/sys/changes/list' + (changes.seen ? `?from=${changes.seen}` : '')));
    changes.head = head;
    // without .git there is no head to mark as seen: nothing to count
    changes.count = !head || changes.seen === head ? 0 : entries.length;
    changes.loaded = true;
  } catch { /* a failed look keeps the old count */ }
}

export async function markSeen(head) {
  if (!head) return;
  try {
    await markChangesSeen(head);
    changes.seen = head;
    changes.count = 0;
  } catch { /* the badge stays until the next try */ }
}

// look now and again every five minutes
let timer;
export function startChanges() {
  load();
  timer ??= setInterval(load, 300000);
}
