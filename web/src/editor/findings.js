// The findings of the Test (`finding<TAB>level<TAB>where<TAB>text` lines of docker-app-change.sh, parsed by web-serve.py into [level, where, text])
// mapped to the places they belong to: a line or a path of the compose panel, a line of the env panel, or the banner above the panels.
// Plain data in, plain data out (no CodeMirror): cm.js turns a line or a path into a range.

// "services.web.ports.0" -> ['services', 'web', 'ports', 0]: the first part after `services` is the service name (it holds - and _, never a dot),
// the rest is the path inside it; a number is a list index
export function pathOf(dotted) {
  const parts = String(dotted).split('.').filter((x) => x !== '');
  return parts.map((x, i) => (i >= 2 && /^[0-9]+$/.test(x) ? Number(x) : x));
}

// -> { compose: [{ level, text, line | path }], env: [{ level, text, line }], banner: [{ level, text }] }
export function mapFindings(findings) {
  const out = { compose: [], env: [], banner: [] };
  for (const f of Array.isArray(findings) ? findings : []) {
    if (!Array.isArray(f) || f.length < 3) continue;
    const level = f[0] === 'error' ? 'error' : 'warn';
    const where = String(f[1]);
    const text = String(f[2]);
    let m;
    if ((m = /^compose:([0-9]+)$/.exec(where))) out.compose.push({ level, text, line: Number(m[1]) });
    else if ((m = /^compose:(.+)$/.exec(where))) out.compose.push({ level, text, path: pathOf(m[1]) });
    else if ((m = /^env:([0-9]+)$/.exec(where))) out.env.push({ level, text, line: Number(m[1]) });
    else out.banner.push({ level, text });
  }
  return out;
}

// does the answer of a Test hold an error (a refused plan with findings)
export const hasErrors = (findings) => (Array.isArray(findings) ? findings : []).some((f) => Array.isArray(f) && f[0] === 'error');
