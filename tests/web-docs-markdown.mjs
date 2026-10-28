// The Markdown renderer of the web interface (web/src/docs/markdown.js): the syntax the guides use, nothing unsafe, every guide renders.
import { readFileSync, readdirSync } from 'node:fs';
import { render, headingId, plain } from '../web/src/docs/markdown.js';

let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };
const has = (name, html, frag) => check(name, html.includes(frag), `\n    wanted: ${frag}\n    got:    ${html.slice(0, 400)}`);
const R = (src, ctx) => render(src, ctx).html;

console.log('-- blocks');
has('heading with an id', R('## Platte leeren'), '<h2 id="platte-leeren">Platte leeren</h2>');
has('a repeated heading gets a number', R('# A\n\n# A'), 'id="a-1"');
has('paragraph', R('one\ntwo'), '<p>one two</p>');
has('hard break', R('one  \ntwo'), 'one<br>two');
has('fenced code is escaped', R('```bash\necho "<b>"\n```'), '<pre><code class="language-bash">echo &quot;&lt;b&gt;&quot;\n</code></pre>');
has('rule', R('a\n\n---\n\nb'), '<hr>');
has('quote', R('> hi\n> there'), '<blockquote><p>hi there</p></blockquote>');
has('table head', R('| a | b |\n| --- | --- |\n| 1 | 2 |'), '<th>a</th><th>b</th>');
has('table cell', R('| a | b |\n| --- | --- |\n| 1 | 2 |'), '<td>1</td><td>2</td>');
has('escaped pipe stays in the cell', R('| a | b |\n| --- | --- |\n| `x \\| y` | 2 |'), '<code>x | y</code>');
has('table alignment', R('| a |\n| ---: |\n| 1 |'), 'text-align:right');
has('bullet list', R('- one\n- two'), '<ul><li>one</li><li>two</li></ul>');
has('numbered list keeps its start', R('3. x\n4. y'), '<ol start="3">');
has('nested list', R('- a\n  - b\n- c'), '<li>a<ul><li>b</li></ul></li><li>c</li>');
has('task list', R('- [ ] open\n- [x] done'), '<span class="task done"');
has('task text sits in its own box', R('- [ ] a **b** c'), '<div class="taskbody">a <strong>b</strong> c</div>');
has('a loose list has paragraphs', R('- a\n\n- b'), '<li><p>a</p></li>');
has('list item continues on an indented line', R('- a\n  more'), '<li>a more</li>');
has('code inside a list item', R('1. run\n   ```\n   hs x\n   ```\n2. next'), '<li>run<pre><code>hs x\n</code></pre></li>');
has('a sentence ending in a number is no list', R('Seit 2024.\n2. Juli ist es so'), '<p>Seit 2024. 2. Juli ist es so</p>');
has('indented code at the top', R('text\n\n    hs x\n'), '<pre><code>hs x\n</code></pre>');

console.log('-- inline');
has('bold', R('a **b** c'), '<strong>b</strong>');
has('italic', R('a *b* c'), '<em>b</em>');
has('strike', R('a ~~b~~ c'), '<del>b</del>');
has('underscore in a word is left alone', R('see snake_case_name here'), 'snake_case_name');
has('code span keeps marks', R('`**x**`'), '<code>**x**</code>');
has('double backtick span', R('`` a`b ``'), '<code>a`b</code>');
has('escaped star', R('2 \* 3'), '2 * 3');
has('image shows its alt text', R('![logo](x.png)'), 'logo');
check('image makes no tag', !R('![logo](x.png)').includes('<img'));

console.log('-- links');
has('external link opens a new tab', R('[x](https://example.com/a)'), '<a href="https://example.com/a" target="_blank" rel="noopener noreferrer">x</a>');
has('anchor', R('[x](#platte-leeren)'), 'data-anchor="platte-leeren"');
const resolve = (h) => (h.startsWith('Torrents') || h.includes('torrents') ? { lang: 'de', slug: 'torrents-mit-vpn', hash: '' } : null);
has('guide link', R('[t](Torrents%20mit%20VPN.md)', { resolve }), 'data-doc="de/torrents-mit-vpn"');
check('unknown link keeps the text only', R('[t](nowhere.md)', { resolve }) === '<p>t</p>');
check('javascript: is no link', !R('[x](javascript:alert(1))').includes('<a'));
check('data: is no link', !R('[x](data:text/html,<script>)').includes('<a'));
has('autolink', R('<https://example.com>'), 'href="https://example.com"');
has('paren in the address', R('[w](https://x.org/a_(b))'), 'href="https://x.org/a_(b)"');

console.log('-- nothing unsafe');
const evil = R('<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[a](https://x.org" onmouseover="alert(1))\n\n`<b>`');
check('no script tag', !/<script/i.test(evil), evil);
check('no raw img tag', !/<img/i.test(evil), evil);
check('a hostile address stays inside its attribute', [...evil.matchAll(/<a [^>]*>/g)].every((t) => /^<a href="[^"]*" target="_blank" rel="noopener noreferrer">$/.test(t[0])), evil);

console.log('-- helpers');
check('headingId', headingId('Ordner auf eine andere Platte verschieben') === 'ordner-auf-eine-andere-platte-verschieben');
check('headingId drops punctuation', headingId('`hs backup` (neu)!') === 'hs-backup-neu');
check('plain strips marks', plain('**a** `b` [c](d)') === 'a b c');

console.log('-- every guide renders');
const dir = new URL('../docs/', import.meta.url);
const allowed = new Set(['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'a', 'strong', 'em', 'del', 'code', 'pre', 'blockquote', 'ul', 'ol', 'li', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'div', 'span', 'hr', 'br']);
let pages = 0, tables = 0, problems = [];
for (const f of readdirSync(dir).filter((x) => x.endsWith('.md'))) {
  const src = readFileSync(new URL(f, dir), 'utf8');
  let r;
  try { r = render(src, { resolve: () => null }); } catch (e) { problems.push(`${f}: ${e.message}`); continue; }
  pages++;
  tables += (r.html.match(/<table>/g) || []).length;
  for (const t of r.html.matchAll(/<\/?([a-zA-Z][a-zA-Z0-9]*)/g)) if (!allowed.has(t[1].toLowerCase())) problems.push(`${f}: <${t[1]}>`);
  if (/\*\*[^<]{1,80}\*\*/.test(r.html.replace(/<code>.*?<\/code>/g, '').replace(/<pre>.*?<\/pre>/gs, ''))) problems.push(`${f}: a ** is left over`);
  if (src.length > 200 && r.html.length < 100) problems.push(`${f}: nearly empty`);
}
check(`all ${pages} guides render without a problem`, problems.length === 0, '\n    ' + problems.slice(0, 8).join('\n    '));
check('the tables of the guides are tables', tables > 20, String(tables));

console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
