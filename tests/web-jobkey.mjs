// Which running job belongs to which button (web/src/jobkey.js).
import { jobKey, jobMatches } from '../web/src/jobkey.js';

let ok = 0, bad = 0;
const check = (name, cond) => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name}`); } };

check('key joins area and args', jobKey('routes', ['apply', '--proxy', 'local']) === 'routes apply --proxy local');
check('key of an area alone', jobKey('ct') === 'ct');
check('same plan matches', jobMatches('routes apply', 'routes', ['apply']));
check('other args do not match', !jobMatches('routes apply', 'routes', ['adopt']));
check('apply is not apply --proxy local', !jobMatches('routes apply --proxy local', 'routes', ['apply']));
check('apply --proxy local matches itself', jobMatches('routes apply --proxy local', 'routes', ['apply', '--proxy', 'local']));
check('a prefix of a word is not a match', !jobMatches('routes applyall', 'routes', ['apply']));
check('area alone matches any job of it', jobMatches('routes import', 'routes'));
check('area alone does not match another area', !jobMatches('ct update-all', 'routes'));
check('area prefix is whole word', !jobMatches('routesx apply', 'routes'));
check('empty key never matches', !jobMatches('', 'routes') && !jobMatches(undefined, 'routes', ['apply']));

console.log(`${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
