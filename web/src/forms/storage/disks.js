// helpers of the storage forms
import { sizeTxt, spaceTxt } from '../../pages/storage/pool.js';

// `pool disks` rows: by-id name, bytes, SSD|HDD, notes ("[has ext4 files] [encrypted: not this server's]")
export const freeDisks = (rowList) => rowList.map((r) => {
  const notes = [...(r[3] ?? '').matchAll(/\[([^\]]*)\]/g)].map((m) => m[1]);
  const hasFiles = notes.some((n) => /^has .* files$/.test(n));
  const size = sizeTxt(Number(r[1]));
  // r[4] (adopt list only) = used bytes read from the superblock; a blank disk is all free; unknown used space shows only the size
  return { id: r[0], bytes: Number(r[1]), size, space: r[4] !== undefined && r[4] !== '' ? spaceTxt(Number(r[1]) - Number(r[4]), Number(r[1])) : hasFiles ? size : spaceTxt(Number(r[1]), Number(r[1])), type: r[2], notes, hasFiles };
});

// a long by-id name: the serial is the end of it
export const shortId = (id) => (id.length > 34 ? `…${id.slice(-32)}` : id);

export const FS = [['ext4', 'ext4 (default, best tested)'], ['xfs', 'xfs (big files, cannot be shrunk)'], ['btrfs', 'btrfs (checksums, more moving parts)']];
