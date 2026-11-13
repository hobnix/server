// Form field components: unit tests of ui/fieldaria.js and a static contract per component source (no svelte in this checkout).
// Run with node, no dependencies.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fieldIds, describedBy, ariaFor } from '../web/src/ui/fieldaria.js';

const src = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'web', 'src');
let failed = 0;
const bad = (m) => { failed++; console.log('FAIL  ' + m); };
const eq = (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) bad(`${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
const must = (name, cond) => { if (!cond) bad(name); };
const read = (p) => fs.readFileSync(path.join(src, p), 'utf8');

eq('fieldIds', fieldIds('f-1'), { help: 'f-1-help', err: 'f-1-err' });
eq('describedBy none', describedBy('f-1', {}), undefined);
eq('describedBy help', describedBy('f-1', { help: true }), 'f-1-help');
eq('describedBy error', describedBy('f-1', { error: true }), 'f-1-err');
eq('describedBy both', describedBy('f-1', { help: true, error: true }), 'f-1-help f-1-err');
eq('ariaFor plain', ariaFor({ id: 'x' }), { id: 'x', 'aria-describedby': undefined, 'aria-invalid': undefined, 'aria-required': undefined });
eq('ariaFor full', ariaFor({ id: 'x', help: true, error: true, required: true }),
  { id: 'x', 'aria-describedby': 'x-help x-err', 'aria-invalid': 'true', 'aria-required': 'true' });

const field = read('ui/Field.svelte');
must('Field: <label for=', /<label for=/.test(field));
must('Field: role="alert" on the error', /class="err"[^>]*role="alert"|role="alert"[^>]*class="err"/.test(field));
must('Field: aria-hidden on the asterisk', /<span aria-hidden="true">/.test(field));
must('Field: setContext', /setContext\('field'/.test(field));

const index = read('ui/index.js');
const native = { TextInput: '<input', Select: '<select', Textarea: '<textarea', Checkbox: '<input type="checkbox"' };
for (const [name, tag] of Object.entries({ Field: '', ...native })) {
  const s = read(`ui/${name}.svelte`);
  must(`${name}: exported from ui/index.js`, new RegExp(`default as ${name} } from './${name}.svelte'`).test(index));
  must(`${name}: no hex colour`, !/#[0-9a-fA-F]{3,8}\b/.test(s));
  if (name === 'Field') continue;
  must(`${name}: native ${tag}`, s.includes(tag));
  must(`${name}: aria-describedby`, s.includes('aria-describedby'));
  must(`${name}: aria-invalid`, s.includes('aria-invalid'));
}
must('Checkbox: label wraps/targets the input', /<label[^>]*for=\{/.test(read('ui/Checkbox.svelte')));
must('fieldaria.js is not svelte', !/from 'svelte'/.test(read('ui/fieldaria.js')));

for (const f of fs.readdirSync(path.join(src, 'forms', 'shares')).filter((x) => x.endsWith('.svelte'))) {
  const s = read(`forms/shares/${f}`);
  if (/<label for=/.test(s) && /<input class="input"/.test(s)) bad(`forms/shares/${f}: raw label for + input.input`);
  if (/<(select|textarea)\b[^>]*class="input"/.test(s) || /<input class="input"/.test(s)) bad(`forms/shares/${f}: raw .input control`);
  if (/<(Field|TextInput|Select|Checkbox)\b/.test(s) && !/from '..\/..\/ui'/.test(s)) bad(`forms/shares/${f}: components not imported from ui`);
}

console.log(failed ? `${failed} failed` : 'ok');
process.exit(failed ? 1 : 0);
