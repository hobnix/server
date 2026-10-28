// No plain html element in web/src/**/*.svelte may carry a native title= attribute: tooltips go through the shared component
// (use:tip, web/src/ui/tooltip.svelte.js). Component PROPS named title (<Drawer title=...>, capitalised tags) are fine. Also: a file that uses
// use:tip must import it. Run with node, no dependencies.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'web', 'src');
let failed = 0, checked = 0, tips = 0;
const bad = (m) => { failed++; console.log('FAIL  ' + m); };

function walk(d, out = []) {
  for (const f of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, f.name);
    if (f.isDirectory()) walk(p, out); else if (p.endsWith('.svelte')) out.push(p);
  }
  return out;
}
function skipStr(s, j) {
  const q = s[j]; let k = j + 1;
  while (k < s.length) {
    if (s[k] === '\\') { k += 2; continue; }
    if (q === '`' && s[k] === '$' && s[k + 1] === '{') {
      let d = 1; k += 2;
      while (k < s.length && d > 0) { if (s[k] === '{') d++; else if (s[k] === '}') d--; else if (s[k] === '"' || s[k] === "'" || s[k] === '`') k = skipStr(s, k); k++; }
      continue;
    }
    if (s[k] === q) return k;
    k++;
  }
  return k;
}
// the end of an opening tag whose name ends at i; attributes are quoted strings or {expressions}
function tagEnd(s, i) {
  let depth = 0, q = '';
  for (let j = i; j < s.length; j++) {
    const c = s[j];
    if (q) { if (c === q) q = ''; continue; }
    if (depth > 0) {
      if (c === '"' || c === "'" || c === '`') { j = skipStr(s, j); continue; }
      if (c === '{') depth++; else if (c === '}') depth--;
      continue;
    }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === '{') { depth = 1; continue; }
    if (c === '>') return j;
  }
  return -1;
}
// is `title=` an attribute of the tag at the top level (not inside a {expression} or a quoted value)?
function hasTitleAttr(body) {
  let depth = 0, q = '';
  for (let k = 0; k < body.length; k++) {
    const c = body[k];
    if (q) { if (c === q) q = ''; continue; }
    if (depth > 0) {
      if (c === '"' || c === "'" || c === '`') { k = skipStr(body, k); continue; }
      if (c === '{') depth++; else if (c === '}') depth--;
      continue;
    }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === '{') { if (/\s/.test(body[k - 1] ?? '') && /^\{\s*title\s*\}/.test(body.slice(k))) return true; depth = 1; continue; }   // the shorthand {title}
    if (/\s/.test(c) && /^title\s*=/.test(body.slice(k + 1))) return true;
  }
  return false;
}

for (const file of walk(root)) {
  const s = fs.readFileSync(file, 'utf8');
  const rel = path.relative(root, file).replace(/\\/g, '/');
  const masks = [];
  for (const m of s.matchAll(/<(script|style)\b[\s\S]*?<\/\1>/g)) masks.push([m.index, m.index + m[0].length]);
  for (const m of s.matchAll(/<!--[\s\S]*?-->/g)) masks.push([m.index, m.index + m[0].length]);
  const masked = (i) => masks.some(([a, b]) => i >= a && i < b);
  checked++;
  const re = /<([a-z][a-z0-9]*)(?=[\s>])/g;
  let m;
  while ((m = re.exec(s))) {
    if (masked(m.index)) continue;
    const end = tagEnd(s, m.index + m[0].length);
    if (end < 0) continue;
    if (hasTitleAttr(s.slice(m.index + m[0].length, end))) {
      bad(`${rel}:${s.slice(0, m.index).split('\n').length} <${m[1]}> has a title= attribute: use use:tip={...}`);
    }
  }
  if (/\buse:tip\b/.test(s) && !/import\s*\{[^}]*\btip\b[^}]*\}\s*from/.test(s)) bad(`${rel} uses use:tip but does not import tip`);
  tips += (s.match(/\buse:tip\b/g) || []).length;
}

// the Docs copy buttons are made by hand, outside Svelte: they must ask for the tooltip too
const docs = fs.readFileSync(path.join(root, 'pages', 'Docs.svelte'), 'utf8');
if (!/tip\(b,/.test(docs)) bad('pages/Docs.svelte: the copy button of a code block has no tooltip');

console.log(failed ? `-> ${failed} failed` : `ok    no title= attribute on a plain element in ${checked} files (${tips} use:tip)`);
process.exit(failed ? 1 : 0);
