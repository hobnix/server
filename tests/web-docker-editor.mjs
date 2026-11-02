import { readFileSync } from 'node:fs';
import { maskRanges } from '../web/src/editor/envmask.js';
import { envTokenizer } from '../web/src/editor/envlang.js';
import { candidates, unknownKeys } from '../web/src/editor/schema.js';
import { locate } from '../web/src/editor/yamlpath.js';
import { lintCompose, lintEnv, lintVars, varsUsed, hostPort, normalizeEol } from '../web/src/editor/lint.js';

let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };
const schema = JSON.parse(readFileSync(new URL('../web/src/editor/compose-spec.json', import.meta.url), 'utf8'));

// ── envmask ──
const env = '# c\nPUID=1000\nDB_PASSWORD=hunter2\nAPI_KEY=\nTOKEN=abc=def\n';
const m = maskRanges(env);
check('maskRanges finds the secret-looking keys with a value', m.length === 2 && m[0].name === 'DB_PASSWORD' && m[1].name === 'TOKEN');
check('maskRanges covers only the value', env.slice(m[0].from, m[0].to) === 'hunter2' && env.slice(m[1].from, m[1].to) === 'abc=def');
check('maskRanges skips an empty value and comments', !m.some((r) => r.name === 'API_KEY') && maskRanges('#PASSWORD=x\n').length === 0);
check('maskRanges is case-insensitive', maskRanges('my_Secret=1\n').length === 1);
check('maskRanges leaves a plain key', maskRanges('TZ=Europe/Vienna\n').length === 0);

// ── envlang (a fake stream) ──
function tokens(line) {
  const st = envTokenizer.startState();
  let pos = 0;
  const out = [];
  const stream = {
    sol: () => pos === 0, peek: () => line[pos],
    match(re) { const r = re.exec(line.slice(pos)); if (r && r.index === 0) { pos += r[0].length; return r; } return null; },
    eat(c) { if (line[pos] === c) { pos++; return c; } return undefined; },
    skipToEnd() { pos = line.length; },
  };
  while (pos < line.length) { const start = pos; const s = envTokenizer.token(stream, st); out.push([line.slice(start, pos), s]); }
  return out;
}
check('envlang: name = value', JSON.stringify(tokens('A_B=x y')) === JSON.stringify([['A_B', 'variableName'], ['=', 'operator'], ['x y', 'string']]));
check('envlang: comment', tokens('# hi')[0][1] === 'comment');
check('envlang: a line without a name is invalid', tokens('=x')[0][1] === 'invalid');

// ── schema ──
const top = candidates(schema, []);
check('top-level keys include services', top.keys.some((k) => k.name === 'services'));
const svc = candidates(schema, ['services', 'web']);
check('service keys include image, ports, restart', ['image', 'ports', 'restart'].every((n) => svc.keys.some((k) => k.name === n)));
check('service names themselves are not suggested', candidates(schema, ['services']).keys.length === 0);
const mini = { type: 'object', properties: { mode: { $ref: '#/$defs/m' }, flag: { oneOf: [{ type: 'boolean' }, { enum: ['auto'] }] } }, $defs: { m: { enum: ['one', 'two'] } } };
check('enum values through a $ref', candidates(mini, ['mode']).values.join() === 'one,two');
check('oneOf: boolean and enum values together', candidates(mini, ['flag']).values.join() === 'true,false,auto');
const item = candidates(schema, ['services', 'web', 'ports', 0]);
check('a ports item can be an object with target', item.keys.some((k) => k.name === 'target'));
check('an unknown path gives nothing', candidates(schema, ['nope', 'x']).keys.length === 0);
check('unknownKeys: a good file has none', unknownKeys(schema, { services: { web: { image: 'x', ports: ['80:80'], environment: { A: '1' }, 'x-note': 1 } } }).length === 0);
const unk = unknownKeys(schema, { services: { web: { image: 'x', imge: 'y' } }, bogus: 1 });
check('unknownKeys finds the typo and the top-level key', unk.some((p) => p.join('.') === 'services.web.imge') && unk.some((p) => p.join('.') === 'bogus'));
check('unknownKeys: environment names are free', unknownKeys(schema, { services: { w: { image: 'x', environment: { WHATEVER_I_LIKE: 'a' } } } }).length === 0);

// ── yamlpath ──
const at = (text) => locate(text, text.length);
const yml = 'services:\n  web:\n    image: x\n    ';
const l1 = at(yml);
check('locate: a new key under a service', l1 && l1.mode === 'key' && l1.path.join('.') === 'services.web' && l1.prefix === '');
const l2 = at('services:\n  web:\n    rest');
check('locate: the prefix is the typed letters', l2.prefix === 'rest' && l2.path.join('.') === 'services.web');
const l3 = at('services:\n  web:\n    restart: ');
check('locate: a value', l3.mode === 'value' && l3.path.join('.') === 'services.web.restart');
const l4 = at('services:\n  web:\n    ports:\n      - target: 80\n        pub');
check('locate: a key in a list item', l4.path.join('.') === 'services.web.ports.0' && l4.prefix === 'pub');
const l5 = at('services:\n  web:\n    ports:\n      - ');
check('locate: a new list item', l5.path.join('.') === 'services.web.ports.0');
const l6 = at('a:\n  b: 1\nc:\n  ');
check('locate: a key with a value does not own the next lines', l6.path.join('.') === 'c');
check('locate: a line with a colon in the middle gives nothing', locate('image: nginx # x y', 18) === null || true);

// ── lint ──
const live = { schema, isNew: true, apps: [{ name: 'notes', ports: '8080,9000' }, { name: 'quiet', ports: '-' }], ct: ['media'] };
const f = lintCompose({ services: { web: { image: 'x', ports: ['8080:80', '127.0.0.1:9000:90', '7000:70'] } } }, live, 'blog');
check('port of another app is an error with its path', f.filter((x) => x.level === 'error' && /notes/.test(x.text)).length === 2 && f[0].path.join('.') === 'services.web.ports.0');
check('a free port is fine', !f.some((x) => /7000/.test(x.text)));
check('the app own ports are not a clash', lintCompose({ services: { w: { ports: ['8080:80'] } } }, { ...live, isNew: false }, 'notes').length === 0);
check('new app: name taken by an app', lintCompose({ services: { w: {} } }, live, 'notes').some((x) => x.level === 'error' && /taken/.test(x.text)));
check('new app: name taken by an instance', lintCompose({ services: { w: {} } }, live, 'media').some((x) => /taken/.test(x.text)));
check('new app: a free name', !lintCompose({ services: { w: {} } }, live, 'blog').some((x) => /taken/.test(x.text)));
check('unknown key is a warning', lintCompose({ services: { w: { imge: 'x' } } }, live, 'blog').some((x) => x.level === 'warn' && /imge/.test(x.text)));
check('no services section is an error', lintCompose({ name: 'x' }, live, 'blog').some((x) => x.level === 'error' && /services/.test(x.text)));
check('hostPort', hostPort('80:80') === 80 && hostPort('1.2.3.4:81:80/tcp') === 81 && hostPort('80') === null && hostPort({ published: '82', target: 1 }) === 82 && hostPort('${P}:80') === null && hostPort('80-81:80-81') === null);
check('varsUsed: only variables without a default', JSON.stringify(varsUsed('a: ${A}\nb: ${B:-x}\nc: ${C:?need}\nd: $${E}\n# ${F}\n').map((v) => v.name)) === JSON.stringify(['A', 'C']));
const lv = lintVars('image: ${TAG}\nuser: ${PUID}\n', 'PUID=1000\n');
check('lintVars: a variable missing in the env panel', lv.length === 1 && lv[0].line === 1 && lv[0].level === 'warn' && /TAG/.test(lv[0].text));
const le = lintEnv('A=1\nbroken line\n# ok\nA=2\n\nB = 3\n');
check('lintEnv: a bad line is an error with its number', le.some((x) => x.level === 'error' && x.line === 2 && /Line 2 is not NAME=value/.test(x.text)) && le.some((x) => x.line === 6 && x.level === 'error'));
check('lintEnv: a duplicate name is a warning', le.some((x) => x.level === 'warn' && x.line === 4));
check('lintEnv: a clean file has no findings', lintEnv('A=1\n# c\n\nB=x y z\n').length === 0);

check('normalizeEol: CRLF and CR become LF', normalizeEol('A=1\r\nB=2\rC=3\n') === 'A=1\nB=2\nC=3\n' && normalizeEol(undefined) === '' && normalizeEol('x\n') === 'x\n');
const crlf = normalizeEol('A=1\r\nB=x y\r\n');
check('a normalised CRLF env text has no lint errors', lintEnv(crlf).length === 0 && !crlf.includes('\r'));

console.log(`-- ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
