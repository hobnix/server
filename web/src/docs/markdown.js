// A small Markdown renderer for the guides (docs/*.md) and nothing else: no dependency, and everything that is not Markdown syntax is
// escaped, so a page can never put a tag, a script or an event handler into the app.
//
//   render(source, { resolve }) -> { html, headings }
//
// Supported: headings (with ids like GitHub's), paragraphs, bold, italic, strike, code spans, fenced and indented code, block quotes,
// bullet / numbered / task lists (nested), tables, rules, links, autolinks, images (shown as their alt text: the guides have none),
// hard line breaks. Raw HTML is shown as text.
//
// Links: http(s) and mailto become real links that open in a new tab. `#id` jumps inside the page (data-anchor). Anything else is looked up
// with `resolve(href)`; it returns { lang, slug, hash } for a page of the guides (data-doc, data-hash) or null (the text stays, no link).

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// the id GitHub gives a heading: lower case, punctuation gone, spaces to dashes
export function headingId(text) {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .trim()
    .replace(/\s/g, '-');
}

// the text of a piece of inline Markdown without the marks (for heading ids and the outline)
export function plain(text) {
  return text
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/`+([^`]*)`+/g, '$1')
    .replace(/(\*\*|__|~~)/g, '')
    .replace(/(^|\W)[*_](\S[^*_]*\S|\S)[*_](?=\W|$)/g, '$1$2')
    .replace(/\\([\\`*_{}[\]()#+\-.!|~<>])/g, '$1')
    .trim();
}

const SAFE_URL = /^(https?:\/\/|mailto:)/i;

// ── inline ──
function inline(src, ctx) {
  const tokens = [];
  const put = (html) => {
    tokens.push(html);
    return `\u0000${tokens.length - 1}\u0000`;
  };
  let out = '';
  let i = 0;
  const n = src.length;
  let raw = '';
  const flush = () => {
    out += esc(raw);
    raw = '';
  };
  while (i < n) {
    const c = src[i];
    if (c === '\\' && i + 1 < n && /[\\`*_{}[\]()#+\-.!|~<>]/.test(src[i + 1])) {
      flush();
      out += put(esc(src[i + 1]));
      i += 2;
      continue;
    }
    if (c === '`') {
      let j = i;
      while (j < n && src[j] === '`') j++;
      const run = src.slice(i, j);
      const end = src.indexOf(run, j);
      // a closing run must be exactly as long (a longer run is something else)
      let close = end;
      while (close !== -1 && src[close + run.length] === '`') {
        let k = close;
        while (k < n && src[k] === '`') k++;
        close = src.indexOf(run, k);
      }
      if (close !== -1) {
        flush();
        let code = src.slice(j, close).replace(/\n/g, ' ');
        if (code.length > 2 && code.startsWith(' ') && code.endsWith(' ') && code.trim()) code = code.slice(1, -1);
        out += put(`<code>${esc(code)}</code>`);
        i = close + run.length;
        continue;
      }
      raw += run;
      i = j;
      continue;
    }
    if (c === '[' || (c === '!' && src[i + 1] === '[')) {
      const image = c === '!';
      const open = image ? i + 1 : i;
      // the matching ] (brackets nest; code spans and escapes are skipped)
      let depth = 0;
      let k = open;
      let close = -1;
      for (; k < n; k++) {
        const ch = src[k];
        if (ch === '\\') { k++; continue; }
        if (ch === '`') {
          let r = k;
          while (r < n && src[r] === '`') r++;
          const e = src.indexOf(src.slice(k, r), r);
          if (e !== -1) { k = e + (r - k) - 1; continue; }
        }
        if (ch === '[') depth++;
        else if (ch === ']') { depth--; if (depth === 0) { close = k; break; } }
      }
      if (close !== -1 && src[close + 1] === '(') {
        // the destination: up to the matching ), parentheses nest, an optional "title" is dropped
        let d = 0;
        let e = close + 1;
        for (; e < n; e++) {
          if (src[e] === '\\') { e++; continue; }
          if (src[e] === '(') d++;
          else if (src[e] === ')') { d--; if (d === 0) break; }
        }
        if (e < n) {
          flush();
          const label = src.slice(open + 1, close);
          let dest = src.slice(close + 2, e).trim();
          const t = dest.match(/^(\S+)\s+("[^"]*"|'[^']*')$/);
          if (t) dest = t[1];
          if (dest.startsWith('<') && dest.endsWith('>')) dest = dest.slice(1, -1);
          if (image) {
            out += put(esc(plain(label)));
          } else {
            out += put(link(dest, inline(label, ctx), ctx));
          }
          i = e + 1;
          continue;
        }
      }
    }
    if (c === '<') {
      const m = src.slice(i).match(/^<((https?:\/\/|mailto:)[^\s<>]+)>/i);
      if (m) {
        flush();
        out += put(link(m[1], esc(m[1]), ctx));
        i += m[0].length;
        continue;
      }
    }
    if (c === '\n') {
      // two spaces (or a backslash) before the line end is a hard break; otherwise the line end is a space
      if (/( {2,}|\\)$/.test(raw)) {
        raw = raw.replace(/( {2,}|\\)$/, '');
        flush();
        out += '<br>';
      } else {
        raw += ' ';
      }
      i++;
      continue;
    }
    raw += c;
    i++;
  }
  flush();
  // emphasis on what is left (code, links and escapes are tokens that hold no marks)
  out = out
    .replace(/\*\*(?=\S)(.+?)(?<=\S)\*\*/g, '<strong>$1</strong>')
    .replace(/(?<![\w])__(?=\S)(.+?)(?<=\S)__(?![\w])/g, '<strong>$1</strong>')
    .replace(/~~(?=\S)(.+?)(?<=\S)~~/g, '<del>$1</del>')
    .replace(/\*(?=\S)(.+?)(?<=\S)\*/g, '<em>$1</em>')
    .replace(/(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])/g, '<em>$1</em>');
  return out.replace(/\u0000(\d+)\u0000/g, (_, k) => tokens[Number(k)]);
}

function link(dest, labelHtml, ctx) {
  if (SAFE_URL.test(dest)) return `<a href="${esc(dest)}" target="_blank" rel="noopener noreferrer">${labelHtml}</a>`;
  if (dest.startsWith('#')) return `<a href="${esc(dest)}" data-anchor="${esc(dest.slice(1))}">${labelHtml}</a>`;
  const hit = ctx?.resolve ? ctx.resolve(dest) : null;
  if (hit) return `<a href="#" data-doc="${esc(hit.lang)}/${esc(hit.slug)}"${hit.hash ? ` data-hash="${esc(hit.hash)}"` : ''}>${labelHtml}</a>`;
  return labelHtml;
}

// ── blocks ──
const FENCE = /^(\s{0,3})(`{3,}|~{3,})\s*([^`\s]*)[^`]*$/;
const HEADING = /^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/;
const RULE = /^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/;
const QUOTE = /^\s{0,3}>\s?/;
const ITEM = /^(\s*)([-*+]|\d{1,9}[.)])(\s+|$)/;
const TABLE_SEP = /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;

function splitCells(line) {
  let s = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1);
  const cells = [];
  let cur = '';
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '\\' && s[i + 1] === '|') { cur += '|'; i++; continue; }
    if (s[i] === '|') { cells.push(cur.trim()); cur = ''; continue; }
    cur += s[i];
  }
  cells.push(cur.trim());
  return cells;
}

function startsBlock(line, afterPara) {
  if (FENCE.test(line) || HEADING.test(line) || QUOTE.test(line) || RULE.test(line)) return true;
  const m = line.match(ITEM);
  if (m) {
    // a numbered list may only interrupt a paragraph when it starts with 1 (a sentence can end in "2024.")
    if (/^\d/.test(m[2]) && afterPara && !/^1[.)]/.test(m[2])) return false;
    return true;
  }
  return false;
}

// A list that starts at lines[i] (m = the match of ITEM for that line). Returns [html, the index after the list].
// Items are the lines indented under the marker (a blank line stays in the item when the next line is indented too); a line that is not
// indented continues the paragraph unless it starts something. Blank lines between items make the list loose (paragraphs with <p>).
function list(lines, i, m, ctx, state) {
  const ordered = /^\d/.test(m[2]);
  const start = ordered ? parseInt(m[2], 10) : 1;
  const siblingLimit = m[0].length;   // a marker indented less than the first item's text is a sibling
  const items = [];
  let loose = false;
  while (i < lines.length) {
    const mm = lines[i].match(ITEM);
    if (!mm || mm[1].length >= siblingLimit || /^\d/.test(mm[2]) !== ordered) break;
    const contentIndent = mm[0].length;
    const body = [lines[i].slice(contentIndent)];
    i++;
    while (i < lines.length) {
      const l = lines[i];
      if (!l.trim()) {
        let k = i + 1;
        while (k < lines.length && !lines[k].trim()) k++;
        if (k < lines.length && lines[k].search(/\S/) >= contentIndent) {
          body.push('');
          loose = loose || false;
          i++;
          continue;
        }
        break;
      }
      const ind = l.search(/\S/);
      if (ind >= contentIndent) { body.push(l.slice(contentIndent)); i++; continue; }
      if (ITEM.test(l) || startsBlock(l, true) || !body[body.length - 1].trim()) break;
      body.push(l.trim());
      i++;
    }
    if (body.some((b, k) => !b.trim() && k < body.length - 1 && body[k + 1] !== undefined && body[k + 1].trim() && !ITEM.test(body[k + 1]))) loose = true;
    items.push(body);
    // blank lines and then a sibling: the list goes on, loosely
    if (i < lines.length && !lines[i].trim()) {
      let k = i;
      while (k < lines.length && !lines[k].trim()) k++;
      const nx = k < lines.length ? lines[k].match(ITEM) : null;
      if (nx && nx[1].length < siblingLimit && /^\d/.test(nx[2]) === ordered) { loose = true; i = k; continue; }
      break;
    }
  }
  const tag = ordered ? 'ol' : 'ul';
  const out = items
    .map((body) => {
      let task = '';
      const t = body[0].match(/^\[([ xX])\]\s+/);
      if (t) {
        task = `<span class="task${t[1] === ' ' ? '' : ' done'}" aria-hidden="true"></span>`;
        body = [body[0].slice(t[0].length), ...body.slice(1)];
      }
      const inner = blocks(body, ctx, state, !loose, true);
      return task ? `<li class="taskitem">${task}<div class="taskbody">${inner}</div></li>` : `<li>${inner}</li>`;
    })
    .join('');
  return [`<${tag}${ordered && start !== 1 ? ` start="${start}"` : ''}>${out}</${tag}>`, i];
}

function blocks(lines, ctx, state, tight, inList = false) {
  let html = '';
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }

    let m = line.match(FENCE);
    if (m) {
      const indent = m[1].length;
      const fence = m[2];
      const body = [];
      i++;
      while (i < lines.length && !(lines[i].trim().startsWith(fence[0].repeat(fence.length)) && /^\s{0,3}[`~]+\s*$/.test(lines[i]))) {
        body.push(lines[i].replace(new RegExp(`^ {0,${indent}}`), ''));
        i++;
      }
      i++;
      html += `<pre><code${m[3] ? ` class="language-${esc(m[3])}"` : ''}>${esc(body.join('\n'))}\n</code></pre>`;
      continue;
    }

    m = line.match(HEADING);
    if (m) {
      const level = m[1].length;
      const text = m[2];
      let id = headingId(plain(text));
      const seen = state.ids;
      if (seen.has(id)) { let k = 1; while (seen.has(`${id}-${k}`)) k++; id = `${id}-${k}`; }
      seen.add(id);
      state.headings.push({ level, id, text: plain(text) });
      html += `<h${level} id="${esc(id)}">${inline(text, ctx)}</h${level}>`;
      i++;
      continue;
    }

    if (RULE.test(line) && !(ITEM.test(line) && /^\s*[-*+]\s/.test(line))) { html += '<hr>'; i++; continue; }

    if (QUOTE.test(line)) {
      const inner = [];
      while (i < lines.length && QUOTE.test(lines[i])) { inner.push(lines[i].replace(QUOTE, '')); i++; }
      html += `<blockquote>${blocks(inner, ctx, state, false, inList)}</blockquote>`;
      continue;
    }

    if (line.includes('|') && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1]) && lines[i + 1].includes('-') && splitCells(line).length === splitCells(lines[i + 1]).length) {
      const head = splitCells(line);
      const align = splitCells(lines[i + 1]).map((c) => (c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : c.startsWith(':') ? 'left' : ''));
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].trim() && lines[i].includes('|')) { rows.push(splitCells(lines[i])); i++; }
      const cell = (tag, t, k) => `<${tag}${align[k] ? ` style="text-align:${align[k]}"` : ''}>${inline(t ?? '', ctx)}</${tag}>`;
      html += `<div class="tablewrap"><table><thead><tr>${head.map((t, k) => cell('th', t, k)).join('')}</tr></thead><tbody>${rows
        .map((r) => `<tr>${head.map((_, k) => cell('td', r[k], k)).join('')}</tr>`)
        .join('')}</tbody></table></div>`;
      continue;
    }

    m = line.match(ITEM);
    if (m) {
      const [h, next] = list(lines, i, m, ctx, state);
      html += h;
      i = next;
      continue;
    }

    // indented code (only where no list is open: list bodies lose their indent before they get here)
    if (/^( {4}|\t)/.test(line) && !inList) {
      const body = [];
      while (i < lines.length && (/^( {4}|\t)/.test(lines[i]) || !lines[i].trim())) { body.push(lines[i].replace(/^( {4}|\t)/, '')); i++; }
      while (body.length && !body[body.length - 1].trim()) body.pop();
      html += `<pre><code>${esc(body.join('\n'))}\n</code></pre>`;
      continue;
    }

    // a paragraph runs until a blank line or the start of another block
    const para = [line.replace(/^\s+/, '')];
    i++;
    while (i < lines.length && lines[i].trim() && !startsBlock(lines[i], true) && !(lines[i].includes('|') && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1]) && lines[i + 1].includes('-'))) {
      para.push(lines[i].replace(/^\s+/, ''));
      i++;
    }
    const text = inline(para.join('\n'), ctx);
    html += tight ? `${text}` : `<p>${text}</p>`;
  }
  return html;
}

export function render(source, ctx = {}) {
  const state = { ids: new Set(), headings: [] };
  const lines = String(source).replace(/\r\n?/g, '\n').replace(/\t/g, '    ').split('\n');
  // list bodies are parsed with the same function: indented code is only for the top level
  const html = blocks(lines, ctx, state, false);
  return { html, headings: state.headings };
}
