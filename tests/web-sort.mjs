// The sorting of the shared table (web/src/shell/sort.js) and the size parser (web/src/format.js).
import { sortRows, nextOrder } from '../web/src/shell/sort.js';
import { sizeToBytes } from '../web/src/format.js';

let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };
const names = (rows) => rows.map((r) => r.n).join(',');

const rows = [{ n: 'disk10', sz: 5, m: '2GiB' }, { n: 'disk2', sz: 30, m: '512MiB' }, { n: 'Disk1', sz: NaN, m: '-' }, { n: 'disk3', sz: 7, m: '12GiB' }];
const cols = [{ key: 'n' }, { key: 'sz', sort: 'num' }, { key: 'm', sort: 'num', value: (r) => sizeToBytes(r.m) }, { key: 'act', sort: false }];

console.log('-- text');
check('the data order without a sort', sortRows(rows, cols, null) === rows);
check('natural order, ascending (disk2 before disk10, case ignored)', names(sortRows(rows, cols, { key: 'n', dir: 'asc' })) === 'Disk1,disk2,disk3,disk10');
check('descending', names(sortRows(rows, cols, { key: 'n', dir: 'desc' })) === 'disk10,disk3,disk2,Disk1');

console.log('-- numbers');
check('ascending, the empty value last', names(sortRows(rows, cols, { key: 'sz', dir: 'asc' })) === 'disk10,disk3,disk2,Disk1');
check('descending, the empty value STILL last', names(sortRows(rows, cols, { key: 'sz', dir: 'desc' })) === 'disk2,disk3,disk10,Disk1');
check('sizes as text sort by their bytes (512MiB < 2GiB < 12GiB)', names(sortRows(rows, cols, { key: 'm', dir: 'asc' })) === 'disk2,disk10,disk3,Disk1');

console.log('-- stability and edge cases');
const tie = [{ n: 'a', k: 1 }, { n: 'b', k: 1 }, { n: 'c', k: 0 }];
check('equal values keep the data order, also descending', names(sortRows(tie, [{ key: 'k', sort: 'num' }], { key: 'k', dir: 'desc' })) === 'a,b,c');
check('a column that is not sortable does nothing', sortRows(rows, cols, { key: 'act', dir: 'asc' }) === rows);
check('an unknown column does nothing', sortRows(rows, cols, { key: 'zzz', dir: 'asc' }) === rows);
check('the input is not changed', names(rows) === 'disk10,disk2,Disk1,disk3');
check('a custom compare function', names(sortRows(rows, [{ key: 'n', sort: (a, b) => a.length - b.length }], { key: 'n', dir: 'asc' })) === 'disk2,Disk1,disk3,disk10');

console.log('-- the click cycle');
const c = { key: 'n' };
const o1 = nextOrder(null, c), o2 = nextOrder(o1, c), o3 = nextOrder(o2, c);
check('none -> ascending -> descending -> none', o1.dir === 'asc' && o2.dir === 'desc' && o3 === null);
check('another column starts ascending', nextOrder({ key: 'x', dir: 'desc' }, c).dir === 'asc');
check('a column that cannot sort keeps the order', nextOrder(o1, { key: 'n', sort: false }) === o1);

console.log('-- sizes');
check('2GiB', sizeToBytes('2GiB') === 2 * 1024 ** 3);
check('512MiB with a space', sizeToBytes('512 MiB') === 512 * 1024 ** 2);
check('1.5TB', sizeToBytes('1.5TB') === 1.5 * 1024 ** 4);
check('a plain number', sizeToBytes('4096') === 4096);
check('no size is NaN', Number.isNaN(sizeToBytes('-')) && Number.isNaN(sizeToBytes('')) && Number.isNaN(sizeToBytes(undefined)));

console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
