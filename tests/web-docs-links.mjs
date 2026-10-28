// The links between the guides: every [text](Other guide.md) in the built pages resolves to a page (web/src/docs/docs.js makeResolver),
// except the few that point at files outside docs/ (README.md, TODO.md, CLAUDE.md ...). Usage: node web-docs-links.mjs <built docs folder>
import { readFileSync, readdirSync } from 'node:fs';
import { makeResolver, parsePath, firstPage } from '../web/src/docs/docs.js';

const out = process.argv[2];
const index = JSON.parse(readFileSync(`${out}/index.json`, 'utf8'));
let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };

const OUTSIDE = new Set(['README.md', 'TODO.md', 'CLAUDE.md', 'machine.toml.example', 'NOTES.md', 'NOTES-a.md']);
let total = 0;
const unresolved = [];
for (const lang of Object.keys(index.langs)) {
  const resolve = makeResolver(index, lang);
  for (const f of readdirSync(`${out}/${lang}`).filter((x) => x.endsWith('.md'))) {
    const src = readFileSync(`${out}/${lang}/${f}`, 'utf8');
    for (const m of src.matchAll(/\]\(([^)\s#]+\.md)(#[^)\s]*)?\)/g)) {
      if (/^https?:/.test(m[1])) continue;
      total++;
      const base = decodeURIComponent(m[1]).split('/').pop();
      if (!resolve(m[1] + (m[2] ?? '')) && !OUTSIDE.has(base) && !base.startsWith('NOTES')) unresolved.push(`${lang}/${f}: ${m[1]}`);
    }
  }
}
check(`all ${total} links between guides resolve (or point outside docs/)`, unresolved.length === 0, '\n    ' + unresolved.slice(0, 10).join('\n    '));

const r = makeResolver(index, 'en');
check('a guide by its file name', r('install.md')?.slug === 'install');
check('a guide of a package by its file name', r('arr.md')?.slug === 'arr' || index.langs.en.groups.every((g) => g.name !== 'Apps'));
check('a slug works too', r('commands.md')?.slug === 'commands');
check('an anchor is kept', r('backup-and-recovery.md#a-b')?.hash === 'a-b');
check('a relative path to a guide resolves by its file name', r('../../docs/storage-and-disks.md')?.slug === 'storage-and-disks');
check('a file that is no guide is nothing', r('machine.toml.example') === null && r('../src/x.md') === null);
check('parsePath', JSON.stringify(parsePath('/docs/en/install')) === '{"lang":"en","slug":"install"}' && parsePath('/docs').lang === '' && parsePath('/instances').slug === '');
check('firstPage is the start page', firstPage(index, 'en') === 'start' && firstPage(index, 'xx') === '');

console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
