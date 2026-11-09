// The form model of the package builder (web/src/pages/builder.js, pure), run with node.
import { blank, manifestText, permissionList, findingsOf, fieldOf } from '../web/src/pages/builder.js';

let ok = 0, bad = 0;
const eq = (name, got, want) => { if (JSON.stringify(got) === JSON.stringify(want)) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); } };

const f = { ...blank(), name: ' demo ', title: 'A "quoted" title' };
eq('a recipe draft', manifestText(f), 'name = "demo"\nversion = "0.1.0"\nkind = "recipe"\ntitle = "A \\"quoted\\" title"\nrequires_core = ">=1"\naudience = "generic"\nscript = "run.sh"\n');
eq('an extension has no script', manifestText({ ...f, kind: 'extension' }).includes('script'), false);
eq('permissions by line or comma', permissionList('web.read\n net:lan, host:incus\n\n'), ['web.read', 'net:lan', 'host:incus']);
eq('permissions are written as a list', manifestText({ ...f, permissions: 'web.read\nnet:lan' }).endsWith('permissions = ["web.read", "net:lan"]\n'), true);
eq('no permissions, no line', manifestText(f).includes('permissions'), false);
eq('a newline in a title stays one TOML line', manifestText({ ...f, title: 'a\nb' }).split('\n').filter((l) => l.startsWith('title')).length, 1);
eq('findings: errors first, - means no place', findingsOf([['warn', '-', 'w'], ['error', 'name', 'e']]), [{ level: 'error', where: 'name', text: 'e' }, { level: 'warn', where: '', text: 'w' }]);
eq('nothing found', findingsOf(undefined), []);
eq('requires_core belongs to the requires field', [fieldOf('requires_core'), fieldOf('title'), fieldOf('-'), fieldOf('')], ['requires', 'title', '', '']);

console.log(`${ok} passed, ${bad} failed`);
process.exit(bad ? 1 : 0);
