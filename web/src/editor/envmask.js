// Which parts of an .env text are hidden in the editor: the values of keys that look like a secret (PASS, TOKEN, SECRET, KEY).
// Pure (no imports): tests/web-docker-editor.mjs runs it with node; cm.js turns the ranges into replace decorations with an eye button.
export const SECRET_KEY = /PASS|TOKEN|SECRET|KEY/i;

// [{ from, to, name }]: offsets of the VALUE (after the first "="); an empty value and comment lines are not masked
export function maskRanges(text) {
  const out = [];
  let pos = 0;
  for (const line of String(text).split('\n')) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(line);
    if (m && SECRET_KEY.test(m[1]) && line.length > m[0].length) out.push({ from: pos + m[0].length, to: pos + line.length, name: m[1] });
    pos += line.length + 1;
  }
  return out;
}
