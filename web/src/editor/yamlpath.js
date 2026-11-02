// Where in a YAML document is the cursor? A line-based guess (indentation), good enough for completion; the real parse is done by `yaml`.
//   locate(text, pos) -> { mode: 'key' | 'value', path, prefix } or null
//   key mode:   path = the mapping the new key goes into (a list item adds the index 0), prefix = the letters typed so far
//   value mode: path = the key whose value is typed, prefix = the letters typed so far
// Pure (no imports): tests/web-docker-editor.mjs runs it with node.
const KEY_LINE = /^(\s*)((?:-\s+)*)("[^"]*"|'[^']*'|[^\s#:'"-][^:#]*?):(?:\s|$)/;
const OPENER = /:\s*(#.*)?$/;

export function locate(text, pos) {
  const upto = String(text).slice(0, pos);
  const lines = upto.split('\n');
  const row = lines.length - 1;
  const cur = lines[row];
  let mode = 'key';
  let prefix = '';
  let keyCol;
  let dashCol = -1;
  let ownKey = null;
  const val = /^(\s*)((?:-\s+)*)([A-Za-z0-9_.-]+):[ \t]+([A-Za-z0-9_.${}:/-]*)$/.exec(cur);
  const key = /^(\s*)((?:-\s+)*)([A-Za-z0-9_.-]*)$/.exec(cur);
  if (val) {
    mode = 'value'; prefix = val[4]; ownKey = val[3];
    keyCol = val[1].length + val[2].length;
    if (val[2]) dashCol = val[1].length;
  } else if (key) {
    prefix = key[3];
    keyCol = key[1].length + key[2].length;
    if (key[2]) dashCol = key[1].length;
  } else {
    return null;
  }
  const path = [];
  let bound = keyCol;
  let seqOwner = false;
  if (dashCol >= 0) { path.unshift(0); bound = dashCol; seqOwner = true; }
  for (let r = row - 1; r >= 0; r--) {
    const line = lines[r];
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const m = KEY_LINE.exec(line);
    if (!m) continue;
    const pkeyCol = m[1].length + m[2].length;
    const pdash = m[2] ? m[1].length : -1;
    const name = m[3].replace(/^["']|["']$/g, '');
    // a key that opens a block (nothing after the colon) and sits left of the cursor owns it; a key with a value on its line never does
    if ((pkeyCol < bound || (seqOwner && pkeyCol === bound && pdash < 0)) && OPENER.test(line)) {
      path.unshift(name);
      bound = pkeyCol;
      seqOwner = false;
    }
    // a "- " left of the cursor starts the list item the cursor is in
    if (pdash >= 0 && pdash < bound) {
      path.unshift(0);
      bound = pdash;
      seqOwner = true;
    }
    if (bound <= 0 && !seqOwner) break;
  }
  if (mode === 'value') path.push(ownKey);
  return { mode, path, prefix };
}
